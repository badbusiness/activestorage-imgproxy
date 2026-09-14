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

1. `ActiveStorage::Variant#process` is prepended. Before the stock implementation
   runs, the gem tries imgproxy with nothing but the blob.
2. It asks the blob for a **short-lived, signed URL to the original**
   (`blob.url(expires_in: …)`) — a presigned URL on S3-like services, the app's own
   signed `/rails/active_storage/disk/…` URL on the Disk service.
3. It builds a signed imgproxy v3 URL (`/{signature}/{options}/{base64 source}.{ext}`),
   streams it to a tempfile, and hands that to Active Storage to upload as the variant.
4. If any of that fails, `super` runs — the untouched stock path, `blob.open` and
   vips included.

imgproxy therefore needs **no storage credentials and no volume mounts**. It only
ever sees a URL that expires in five minutes.

Note the order: on the imgproxy path the original is **never downloaded into the
app**. That is the whole reason the hook sits on `Variant#process` rather than on
the transformer — see [below](#why-the-hook-sits-on-variantprocess).

## Installation

```ruby
# Gemfile
gem "activestorage-imgproxy", github: "badbusiness/activestorage-imgproxy", tag: "v0.2.0"
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
  config.open_timeout   = 2                           # seconds to get a connection
  config.timeout        = 10                          # seconds to read the response
  config.max_bytes      = 64 * 1024 * 1024            # refuse anything bigger
  config.enabled        = true
end
```

## Environment

Three variables per app:

| Variable | Required | Example | Notes |
|---|---|---|---|
| `IMGPROXY_URL` | yes | `http://imgproxy:8080` | Reachable from the app container. No public ingress needed. |
| `IMGPROXY_KEY` | yes | hex string | Must match imgproxy's `IMGPROXY_KEY`. Rejected if it is not hex. |
| `IMGPROXY_SALT` | yes | hex string | Must match imgproxy's `IMGPROXY_SALT`. Rejected if it is not hex. |

And the optional ones:

| Variable | Default | Notes |
|---|---|---|
| `IMGPROXY_SOURCE_HOST` | — | **Required for the Disk service.** Absolute URL of the app *as imgproxy reaches it*, e.g. `https://app.example.com`. |
| `IMGPROXY_URL_EXPIRES_IN` | `300` | Lifetime of the source URL handed to imgproxy. |
| `IMGPROXY_OPEN_TIMEOUT` | `2` | Seconds to get a connection to imgproxy. |
| `IMGPROXY_TIMEOUT` | `10` | Seconds to read the response. |
| `IMGPROXY_MAX_BYTES` | `67108864` | Hard ceiling on the response. Anything bigger falls back. |
| `IMGPROXY_ENABLED` | `true` | `false`/`0`/`no`/`off` switches the gem off completely. |

If `IMGPROXY_URL`, `IMGPROXY_KEY` or `IMGPROXY_SALT` is missing, the gem is
silently inert and everything runs on the stock transformer. That is the intended
behaviour in development and CI. The same is true when Active Storage itself has
variants switched off (`config.active_storage.variant_processor = :disabled`).

### Keep the gem's timeout below imgproxy's

The container has its own `IMGPROXY_TIMEOUT` (default 10 s in imgproxy itself),
which bounds how long *it* will spend fetching and processing a source image.
**The gem's `IMGPROXY_TIMEOUT` must be lower than the container's**, so that the
app gives up first and the fallback starts while imgproxy is still working — rather
than the app waiting out imgproxy's own timeout and only then starting vips. If you
raise one, raise the other by more.

A timeout is deliberately **not** retried, by this gem *or* by Net::HTTP. A timeout
means imgproxy is probably still busy with the first request; asking again doubles
the work on a service that is already struggling and holds the Ruby thread for
another full timeout. Falling back to vips right away is both faster and kinder.

(Net::HTTP retries idempotent requests once on its own — `max_retries` defaults to
`1`, and its retry list includes `Net::ReadTimeout`, `EOFError` and `ECONNRESET`.
The gem sets `max_retries = 0` and does all the counting itself, so "retried once"
means two requests and "never retried" means one. Without that, a hung imgproxy
costs two full read timeouts.)

### The Disk service needs a host — and pays for it

The Disk service cannot build a URL without one, and there is no request in a
background job, so `ActiveStorage::Current.url_options` is derived from
`IMGPROXY_SOURCE_HOST` for the duration of the call. Two things to get right:

- Use the app's **public hostname** (`https://app.example.com`). It is the one
  address that is stable, has a certificate, and does not depend on container
  naming: under Kamal 2 the app container's name carries the deploy's version, so
  there is no stable alias to point imgproxy at.
- The host must be allowed by Rails: add it to `config.hosts` if you use host
  authorization, otherwise the request imgproxy makes is rejected with a 403 and
  every transformation falls back.

#### ⚠️ The self-call trap

On a Disk-service app, imgproxy fetches the original **from the app itself**. So a
variant generated on demand in a web request occupies two threads of the same Puma
at once: the one waiting on imgproxy, and the one serving the original back to it.
Under load that is a self-inflicted deadlock waiting to happen — every thread
waiting on imgproxy is a thread not available to feed it.

On Disk-service apps, therefore:

- **Generate variants in the worker, not in the web process.** Use
  `has_one_attached :photo do |attachable| attachable.variant :thumb, …` with
  `preprocessed: true`, or an explicit job, so the pair of connections lands on a
  process that is not serving users.
- **Avoid on-demand variants in web** (`ActiveStorage::Representations::*Controller`
  hitting an unprocessed variant). If you cannot avoid them, size the Puma thread
  pool with the doubling in mind, or set `IMGPROXY_ENABLED=false` on the web role
  and leave the gem on in the worker.
- On S3-like services none of this applies: imgproxy fetches from the bucket and
  the app is not in the loop at all.

### On the imgproxy side

`IMGPROXY_ALLOWED_SOURCES` must include the host the source URLs point at — the S3
bucket host, or the app host for Disk-service apps.

## What is translated

| Active Storage / ImageProcessing | imgproxy | Notes |
|---|---|---|
| `resize_to_limit: [w, h]` | `rs:fit:w:h:0` | never enlarges |
| `resize_to_fit: [w, h]` | `rs:fit:w:h:1` | |
| `resize_to_fill: [w, h]` | `rs:fill:w:h:1` | |
| `resize_to_fill: [w, h, crop: "north"]` | `rs:fill:w:h:1/g:no` | exact: `centre`/`center`, `north`/`top`, `south`/`bottom`, `east`/`right`, `west`/`left`, and `north-east`, `north-west`, `south-east`, `south-west`. `gravity:` is accepted as a synonym of `crop:`. |
| `resize_to_fill: [w, h, crop: "attention"/"entropy"/"smart"]` | `rs:fill:w:h:1/g:sm` | **an approximation** — see below |
| `resize_and_pad: [w, h, background: [r, g, b] \| "#rrggbb"]` | `rs:fit:w:h:1/ex:1:ce/bg:…` | the background is **required** — see below |
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

Two cases deserve spelling out, because they are the ones where "close enough"
would have been tempting:

- **`crop: "attention"` / `crop: "entropy"` → `g:sm` is an approximation.** vips has
  two distinct smart-crop strategies (`attention` favours faces and high-contrast
  detail, `entropy` favours information density); imgproxy has one, `g:sm`. The crop
  window will usually be the same and will sometimes differ by a few pixels — or,
  on an image with two competing subjects, by rather more. If a variant must be
  pixel-stable across the migration, keep it off imgproxy.
- **`resize_and_pad` requires an explicit `background:`.** Without one, vips pads
  with its own default — black, or transparent when the source has an alpha
  channel — while imgproxy pads with whatever `IMGPROXY_BACKGROUND` says, which the
  gem cannot see. Rather than guess at a colour, `resize_and_pad: [w, h]` falls back
  to vips; adding `background: [255, 255, 255]` puts it back on imgproxy. `alpha:`
  is not supported at all (imgproxy has no equivalent, and silently dropping it
  would produce an opaque image where the app asked for a transparent one).

## Differences from vips

Even for a transformation that translates exactly, imgproxy and vips do not produce
byte-identical output, and in a few cases not visually identical output either.
These are **container settings, not gem settings** — they belong in the imgproxy
deployment, next to the memory cap, and this gem deliberately does not try to paper
over them:

| Difference | Why | What to set on the container |
|---|---|---|
| **Sharpening** | `ImageProcessing::Vips` applies a sharpening mask after downscaling by default (libvips' `thumbnail` uses `SHARPEN_MASK`). imgproxy does not sharpen unless told to, so thumbnails can look slightly softer than the ones the app produced before. | `IMGPROXY_SHARPENING` (start around `0.3`–`0.5` and compare a real thumbnail side by side) |
| **Colour profile** | vips keeps the embedded ICC profile; imgproxy may strip it depending on configuration, which shifts colours on wide-gamut source photos. | `IMGPROXY_STRIP_COLOR_PROFILE` (`false` to keep it) |
| **Quality** | The gem only sends `q:` when the app asked for a quality. Otherwise imgproxy uses its own default, which is not vips' default. | `IMGPROXY_QUALITY`, or set `quality:` on the variant so the app decides |
| **Metadata** | imgproxy strips most metadata by default; vips keeps more of it. | `IMGPROXY_STRIP_METADATA` |

Pick the settings once, on the shared container, and compare a handful of real
variants before switching an app over. Nothing here is a fallback condition: the
gem cannot tell a soft thumbnail from a sharp one.

## Fallback behaviour

The gem falls back to the stock transformer (whatever
`config.active_storage.variant_processor` selects — vips in practice) when:

- a transformation cannot be translated;
- `IMGPROXY_URL`/`KEY`/`SALT` is missing, or the key or salt is not hex;
- the blob cannot produce a source URL (e.g. Disk service without `IMGPROXY_SOURCE_HOST`);
- imgproxy refuses the connection, resets it, or cannot be resolved — retried once;
- imgproxy answers 5xx — retried once;
- imgproxy times out — **not** retried;
- imgproxy answers any other non-200 — not retried, since it will not change its mind;
- imgproxy answers **200 with something that is not the requested image** — an empty
  body, an error page, or an `IMGPROXY_FALLBACK_IMAGE` in another format. The first
  bytes are checked against the file signature for the requested format, because a
  variant is written once and then never regenerated (`#processed?` only asks the
  service whether the key exists), so a bad body would be permanent;
- the response is larger than `IMGPROXY_MAX_BYTES`;
- anything else goes wrong at all. The rescue is deliberately as wide as
  `StandardError`: a typo in a URL, a full disk, an exhausted file-descriptor
  limit or a bug in this gem must produce a slow variant, never a failed request.

Each fallback logs exactly one line:

```
[activestorage-imgproxy] falling back to the stock transformer: ActiveStorage::Imgproxy::RequestFailed: imgproxy request failed after 2 attempts: imgproxy responded 502
```

Note what is *not* in that line: imgproxy's response body. It echoes the source URL
it was handed, which is a presigned S3 URL or a signed Disk URL. Only the status
code is ever reported, in the log and in the instrumentation payload alike.

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

Two things to know about that payload before you ship a subscriber:

- `:transformations` is the variant's own transformation hash. It contains no
  credentials, but it can contain application data if your app builds variants from
  user input — treat it the way you treat parameters, not the way you treat a
  counter.
- `:error` is a class name and a message, never a response body.

Also: on the imgproxy path Active Storage's own `transform.active_storage` event
does **not** fire, because `ActiveStorage::Variation#transform` is not reached.
`transform.imgproxy` is the event to measure; a subscriber that only watches
`transform.active_storage` will see traffic disappear rather than speed up.

**Is it falling back?** Grep the logs for `[activestorage-imgproxy]`. A healthy app
produces none. Any occurrence names the reason on the same line.

**End to end, from a console:**

```ruby
blob = ActiveStorage::Blob.where(content_type: "image/jpeg").last
blob.variant(resize_to_limit: [ 100, 100 ], format: :png).processed.download.bytesize
```

with the subscription above attached — one `transform.imgproxy` event with
`fallback: false` means the bytes came from the container.

## Why the hook sits on `Variant#process`

The obvious place to hook is Active Storage's transformer, and Rails 8.1 even has
an `ActiveStorage.variant_transformer` accessor. It does not work, for two separate
reasons.

The first is that a `Transformer`'s only entry point is
`#process(file, format:)`. It receives an already-open file and never sees the
blob — and the blob is the only thing that can produce a URL imgproxy can fetch the
original from. Worse, by the time it is called the stock code has *already* streamed
the whole original out of storage and checksummed it (`ActiveStorage::Blob#open`
downloads to a tempfile and verifies its MD5). On the imgproxy path that download is
pure waste, and on a Disk-service app it is the self-call trap described above,
doubled.

The second is that the accessor is not a configuration hook anyway: the engine
overwrites it unconditionally from `:variant_processor` in a `config.after_initialize`
block, which runs *after* `config/initializers`.

So the gem prepends two small modules instead (`ActiveStorage::Imgproxy.install!`,
called from a railtie `to_prepare` so it survives code reloading), one level above
the transformer:

- `Ext::Variant` on `ActiveStorage::Variant#process`;
- `Ext::VariantWithRecord` on `ActiveStorage::VariantWithRecord#process`.

Both are private, take no arguments and expose a public `#blob` and `#variation`,
which is what makes a four-line override possible. Together they cover the whole
variant path, previews included (`ActiveStorage::Preview` produces its image and
then goes through `Variant`). Each one tries imgproxy with the blob, and calls
`super` — the completely untouched stock implementation — when that does not work
out. `ActiveStorage::Transformers::ImgproxyTransformer` remains the internal
implementation, driven from those two hooks; it is never installed as Active
Storage's transformer.

`test/installation_test.rb` pins all of this against the real Rails classes, so a
future Rails upgrade that moves the ground fails there first.

## Development

```sh
bundle install
bundle exec rake test
bundle exec rubocop
```

Both run on every pull request and on every push to `main`
(`.github/workflows/ci.yml`), on the Ruby in `.ruby-version`. The suite boots a real Rails application with a Disk service in
`tmp/`, stubs imgproxy with WebMock, checks the signature against the test vector
from the imgproxy documentation, and compares imgproxy's bytes against what vips
would have produced — so it needs a real libvips. `test/socket_test.rb` runs against
a real `TCPServer` with WebMock switched off, because WebMock's `to_timeout` raises
inside its own adapter and never reaches Net::HTTP's retry loop — a retry bug is
invisible to it.

Only Rails 8.1 is tested, and the gemspec says so. The hook sits on two private
methods of `ActiveStorage::Variant` and `ActiveStorage::VariantWithRecord`; claiming
a wider range than CI proves would be a promise this gem cannot keep.

## License

MIT.
