# frozen_string_literal: true

require "test_helper"

class TranslatorTest < Minitest::Test
  include ImgproxyTestHelper

  def test_resize_to_limit_never_enlarges
    assert_equal [ "rs:fit:100:200:0" ], translate(resize_to_limit: [ 100, 200 ])
  end

  def test_resize_to_fit_enlarges
    assert_equal [ "rs:fit:100:200:1" ], translate(resize_to_fit: [ 100, 200 ])
  end

  def test_resize_to_fill_crops
    assert_equal [ "rs:fill:100:200:1" ], translate(resize_to_fill: [ 100, 200 ])
  end

  def test_a_nil_dimension_becomes_zero_meaning_derive_it
    assert_equal [ "rs:fit:100:0:0" ], translate(resize_to_limit: [ 100, nil ])
  end

  def test_crop_gravity_is_translated
    assert_equal [ "rs:fill:100:200:1", "g:no" ], translate(resize_to_fill: [ 100, 200, { crop: "north" } ])
    assert_equal [ "rs:fill:100:200:1", "g:sm" ], translate(resize_to_fill: [ 100, 200, { crop: "attention" } ])
  end

  def test_resize_and_pad_extends_the_canvas
    assert_equal [ "rs:fit:100:200:1", "ex:1:ce" ], translate(resize_and_pad: [ 100, 200 ])
  end

  def test_resize_and_pad_background
    assert_equal [ "rs:fit:100:200:1", "ex:1:ce", "bg:255:255:255" ],
      translate(resize_and_pad: [ 100, 200, { background: [ 255, 255, 255 ] } ])
    assert_equal [ "rs:fit:100:200:1", "ex:1:ce", "bg:ffffff" ],
      translate(resize_and_pad: [ 100, 200, { background: "#ffffff" } ])
  end

  def test_quality_top_level_and_nested_in_saver
    assert_equal [ "q:75" ], translate(quality: 75)
    assert_equal [ "q:75" ], translate(saver: { quality: 75 })
  end

  def test_strip_and_saver_strip
    assert_equal [ "sm:1" ], translate(strip: true)
    assert_equal [ "sm:1" ], translate(saver: { strip: true })
    assert_equal [], translate(strip: false)
  end

  def test_auto_orient_is_a_no_op_because_imgproxy_auto_rotates
    assert_equal [], translate(auto_orient: true)
    assert_equal [ "ar:0" ], translate(auto_orient: false)
  end

  def test_format_is_carried_by_the_url_extension
    assert_equal [], translate(format: :webp)
  end

  def test_combinations_keep_their_order_with_quality_last
    assert_equal [ "rs:fit:800:800:0", "sm:1", "q:80" ],
      translate(resize_to_limit: [ 800, 800 ], strip: true, quality: 80)
  end

  def test_unknown_transformations_are_rejected
    assert_raises(ActiveStorage::Imgproxy::UnsupportedTransformation) { translate(rotate: 90) }
    assert_raises(ActiveStorage::Imgproxy::UnsupportedTransformation) { translate(monochrome: true) }
    assert_raises(ActiveStorage::Imgproxy::UnsupportedTransformation) { translate(combine_options: {}) }
  end

  def test_unknown_resize_options_are_rejected
    assert_raises(ActiveStorage::Imgproxy::UnsupportedTransformation) do
      translate(resize_to_fill: [ 100, 100, { sharpen: 2 } ])
    end
  end

  def test_unknown_saver_options_are_rejected
    assert_raises(ActiveStorage::Imgproxy::UnsupportedTransformation) { translate(saver: { lossless: true }) }
  end

  def test_out_of_range_quality_is_rejected
    assert_raises(ActiveStorage::Imgproxy::UnsupportedTransformation) { translate(quality: 0) }
    assert_raises(ActiveStorage::Imgproxy::UnsupportedTransformation) { translate(quality: 101) }
  end

  def test_bad_dimensions_are_rejected
    assert_raises(ActiveStorage::Imgproxy::UnsupportedTransformation) { translate(resize_to_limit: [ -1, 10 ]) }
    assert_raises(ActiveStorage::Imgproxy::UnsupportedTransformation) { translate(resize_to_limit: "100x100") }
  end

  def test_string_keys_are_accepted
    assert_equal [ "rs:fit:100:100:0" ], translate("resize_to_limit" => [ 100, 100 ])
  end

  private
    def translate(transformations)
      ActiveStorage::Imgproxy::Translator.new(transformations).call
    end
end
