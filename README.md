# activestorage-imgproxy

Run Active Storage variant transformations on a shared [imgproxy](https://imgproxy.net)
container instead of in your Ruby processes — without changing a single view,
variant name or preprocessing job.

Active Storage keeps doing what it does: it decides which variant is needed, stores
the result on its own service, and serves it. Only the engine moves. The
transient 200–300 MB libvips spike of a 48 MP photo, and the heap fragmentation it
leaves behind, leave every web and worker process of every app and end up in one
container with its own memory cap.

**Any problem at all falls back to the transformer Active Storage would otherwise
have used.** imgproxy being slow, down, misconfigured or confused must never turn
into a 500.

## How it works

1. `ActiveStorage::Variation#transformer` is prepended so that the variant
   transformation is handled by `ActiveStorage::Transformers::ImgproxyTransformer`.
2. That transformer asks the blob for a **short-lived, signed URL to the original**
   (`blob.url(expires_in: …)`) — a presigned URL on S3-like services, the app's own
   signed `/rails/active_storage/disk/…` URL on the Disk service.
3. It builds a signed imgproxy v3 URL (`/{signature}/{options}/{base64 source}.{ext}`),
   fetches it over HTTP, and hands the bytes back to Active Storage as a tempfile.

imgproxy therefore needs **no storage credentials and no volume mounts**. It only
ever sees a URL that expires in five minutes.

## Installation

```ruby
# Gemfile
gem "activestorage-imgproxy", github: "badbusiness/activestorage-imgproxy", tag: "v0.1.0"
```

No initializer is required: the railtie installs the hooks and every setting has an
environment default. An initializer is only needed if you want to override something
in code:

```ruby
# config/initializers/imgproxy.rb
ActiveStorage::Imgproxy.configure do |config|
  config.url            = ENV["IMGPROXY_URL"]         # e.g. "http://imgproxy:8080"
  config.key            = ENV["IMGPROXY_KEY"]         # hex
  config.salt           = ENV["IMGPROXY_SALT"]        # hex
  config.source_host    = ENV["IMGPROXY_SOURCE_HOST"] # only needed for the Disk service
  config.url_expires_in = 300                         # seconds the source URL is valid
  config.timeout        = 30                          # seconds per HTTP attempt
  config.enabled        = true
end
```

## Environment

Three variables per app:

| Variable | Required | Example | Notes |
|---|---|---|---|
| `IMGPROXY_URL` | yes | `http://imgproxy:8080` | Reachable from the app container. No public ingress needed. |
| `IMGPROXY_KEY` | yes | hex string | Must match imgproxy's `IMGPROXY_KEY`. |
| `IMGPROXY_SALT` | yes | hex string | Must match imgproxy's `IMGPROXY_SALT`. |

Four optional ones:

| Variable | Default | Notes |
|---|---|---|
| `IMGPROXY_SOURCE_HOST` | — | **Required for the Disk service.** Absolute URL of the app *as imgproxy reaches it*, e.g. `http://madvintage-web:3000`. |
| `IMGPROXY_URL_EXPIRES_IN` | `300` | Lifetime of the source URL handed to imgproxy. |
| `IMGPROXY_TIMEOUT` | `30` | Open/read/write timeout per attempt. |
| `IMGPROXY_ENABLED` | `true` | `false`/`0`/`no`/`off` switches the gem off completely. |

If `IMGPROXY_URL`, `IMGPROXY_KEY` or `IMGPROXY_SALT` is missing, the gem is
silently inert and everything runs on the stock transformer. That is the intended
behaviour in development and CI.

### The Disk service needs a host

The Disk service cannot build a URL without one, and there is no request in a
background job, so `ActiveStorage::Current.url_options` is derived from
`IMGPROXY_SOURCE_HOST` for the duration of the call. Two things to get right:

- imgproxy must be able to resolve and reach that host (a container name on the
  shared Docker network works; the public hostname usually also works but takes a
  detour over the proxy).
- the host must be allowed by Rails: add it to `config.hosts` if you use host
  authorization, otherwise the request imgproxy makes is rejected with a 403 and
  every transformation falls back.

### On the imgproxy side

`IMGPROXY_ALLOWED_SOURCES` must include the host the source URLs point at — the S3
bucket host, or the app host for Disk-service apps.

## What is translated

| Active Storage / ImageProcessing | imgproxy | Notes |
|---|---|---|
| `resize_to_limit: [w, h]` | `rs:fit:w:h:0` | never enlarges |
| `resize_to_fit: [w, h]` | `rs:fit:w:h:1` | |
| `resize_to_fill: [w, h]` | `rs:fill:w:h:1` | |
| `resize_to_fill: [w, h, crop: "north"]` | `rs:fill:w:h:1/g:no` | `centre`, `north`, `south`, `east`, `west`, the four corners, and `attention`/`entropy` → `g:sm` |
| `resize_and_pad: [w, h]` | `rs:fit:w:h:1/ex:1:ce` | |
| `resize_and_pad: [w, h, background: [r, g, b] \| "#rrggbb"]` | `… /bg:r:g:b` | |
| a `nil` dimension | `0` | imgproxy derives it from the other one |
| `format: :webp` | the URL extension | Active Storage handles this itself |
| `quality: 80`, `saver: { quality: 80 }` | `q:80` | |
| `strip: true`, `saver: { strip: true }` | `sm:1` | |
| `auto_orient: true` | *(nothing)* | imgproxy auto-rotates by default |
| `auto_orient: false` | `ar:0` | |

**Everything else falls back**, including `rotate`, `crop`, `monochrome`,
`combine_options`, unknown `saver` keys, and anything with a nonsensical argument.
There is no guessing: if the gem cannot express a transformation exactly, it does
not run it.

## Fallback behaviour

The gem falls back to the stock transformer (whatever
`config.active_storage.variant_processor` selects — vips in practice) when:

- a transformation cannot be translated;
- `IMGPROXY_URL`/`KEY`/`SALT` is missing;
- the blob cannot produce a source URL (e.g. Disk service without `IMGPROXY_SOURCE_HOST`);
- imgproxy times out, refuses the connection, or cannot be resolved — retried once;
- imgproxy answers 5xx — retried once;
- imgproxy answers any other non-200 — not retried, since it will not change its mind.

Each fallback logs exactly one line:

```
[activestorage-imgproxy] falling back to ActiveStorage::Transformers::Vips: ActiveStorage::Imgproxy::RequestFailed: imgproxy request failed after 2 attempts: imgproxy responded 502
```

## Verifying it in production

**Is it on?**

```ruby
ActiveStorage::Imgproxy.config.enabled?  # => true
ActiveStorage::Imgproxy.installed?       # => true
```

**Is it actually being used?** Subscribe to the instrumentation — payload carries
`:transformations`, `:format`, `:duration` (seconds), `:fallback` and, on a
fallback, `:error`:

```ruby
ActiveSupport::Notifications.subscribe("transform.imgproxy") do |event|
  Rails.logger.info(
    "imgproxy #{event.payload[:fallback] ? 'FALLBACK' : 'ok'} " \
    "#{(event.payload[:duration] * 1000).round}ms #{event.payload[:error]}"
  )
end
```

**Is it falling back?** Grep the logs for `[activestorage-imgproxy]`. A healthy app
produces none. Any occurrence names the reason on the same line.

**End to end, from a console:**

```ruby
blob = ActiveStorage::Blob.where(content_type: "image/jpeg").last
blob.variant(resize_to_limit: [ 100, 100 ], format: :png).processed.download.bytesize
```

with the subscription above attached — one `transform.imgproxy` event with
`fallback: false` means the bytes came from the container.

## Why a prepend and not a configuration option

`ActiveStorage::Variation#transformer` is the single place where Active Storage
decides which transformer runs. Rails 8.1 added the `ActiveStorage.variant_transformer`
accessor, but it is not a configuration hook: the engine overwrites it
unconditionally from `:variant_processor` in a `config.after_initialize` block,
which runs *after* `config/initializers`. Rails 7.1, 7.2 and 8.0 do not have the
accessor at all and hardcode `ImageProcessingTransformer`.

So the gem prepends two small modules (`ActiveStorage::Imgproxy.install!`, called
from a railtie `to_prepare` so it survives code reloading):

- `Ext::Variation` on `ActiveStorage::Variation`, returning the imgproxy
  transformer and handing it the stock one as its fallback;
- `Ext::BlobTracking` on `ActiveStorage::Variant` and
  `ActiveStorage::VariantWithRecord`, which publishes the blob for the duration of
  the transformation.

That second one exists because `Transformer#process(file, format:)` only receives an
open file — it never sees the blob, and imgproxy needs a URL only the blob can
produce. Both classes open the blob and then hand the file to the variation
(`Variant#process`, `VariantWithRecord#process`), both expose a public `#blob`, so a
single module covers the whole variant path, previews included. The blob is set on
the current thread for the duration of that call and restored afterwards.

## Development

```sh
bundle install
bundle exec rake test
bundle exec rubocop
```

The suite boots a real Rails application with a Disk service in `tmp/`, stubs
imgproxy with WebMock, and checks the signature against the test vector from the
imgproxy documentation.

## License

MIT.
