#!/usr/bin/env ruby
# frozen_string_literal: true

require 'bundler/setup'
require 'gtk4'
require 'exif'
require 'yaml'
require 'fileutils'

class ImageViewer < Gtk::Application
  SUPPORTED_EXTENSIONS = %w[.jpg .jpeg .png .webp .tiff .tif .bmp].freeze
  META_FILE = 'imgview_meta.yml'
  ZOOM_STEP = 0.1
  MIN_ZOOM = 0.1
  MAX_ZOOM = 10.0

  def initialize(directory = nil)
    super('com.example.imageviewer', :flags_none)
    @images = []
    @current_index = 0
    @zoom_level = 1.0
    @fit_to_window = true
    @metadata = { 'status' => {} }
    @directory = directory
    @preloaded_pixbuf = nil
    @preload_index = nil

    signal_connect('activate') { on_activate }
  end

  private

  def on_activate
    build_ui
    if @directory && File.directory?(@directory)
      load_images
      show_current_image
    else
      show_directory_chooser
    end
  end

  def build_ui
    @window = Gtk::ApplicationWindow.new(self)
    @window.title = 'Image Viewer'
    @window.set_default_size(1200, 800)

    # Main vertical box
    vbox = Gtk::Box.new(:vertical, 0)
    @window.child = vbox

    # Header bar with status
    @header = Gtk::HeaderBar.new
    @window.titlebar = @header

    # Status label in header
    @status_label = Gtk::Label.new('')
    @status_label.add_css_class('status-label')
    @header.pack_end(@status_label)

    # Copy button
    copy_button = Gtk::Button.new(label: 'Copy Pinned')
    copy_button.signal_connect('clicked') { show_copy_dialog }
    @header.pack_start(copy_button)

    # Scrolled window for image
    @scrolled_window = Gtk::ScrolledWindow.new
    @scrolled_window.hexpand = true
    @scrolled_window.vexpand = true
    vbox.append(@scrolled_window)

    # Image widget
    @image = Gtk::Picture.new
    @image.can_shrink = true
    @image.keep_aspect_ratio = true
    @scrolled_window.child = @image

    # Info bar at bottom
    @info_bar = Gtk::Label.new('')
    @info_bar.xalign = 0
    @info_bar.margin_start = 10
    @info_bar.margin_end = 10
    @info_bar.margin_top = 5
    @info_bar.margin_bottom = 5
    vbox.append(@info_bar)

    # Key controller
    key_controller = Gtk::EventControllerKey.new
    key_controller.signal_connect('key-pressed') do |_controller, keyval, _keycode, state|
      handle_key_press(keyval, state)
    end
    @window.add_controller(key_controller)

    # Apply CSS
    apply_css

    @window.present
  end

  def apply_css
    css_provider = Gtk::CssProvider.new
    css_provider.load_from_data(<<~CSS)
      .status-label {
        font-weight: bold;
        padding: 5px 10px;
      }
      .pinned {
        background-color: #4CAF50;
        color: white;
        border-radius: 3px;
      }
      .skipped {
        background-color: #f44336;
        color: white;
        border-radius: 3px;
      }
    CSS
    Gtk::StyleContext.add_provider_for_display(
      Gdk::Display.default,
      css_provider,
      Gtk::StyleProvider::PRIORITY_APPLICATION
    )
  end

  def show_directory_chooser
    dialog = Gtk::FileChooserDialog.new(
      title: 'Select Image Directory',
      parent: @window,
      action: :select_folder,
      buttons: [['Cancel', :cancel], ['Open', :accept]]
    )
    dialog.modal = true

    dialog.signal_connect('response') do |d, response|
      if response == Gtk::ResponseType::ACCEPT
        @directory = d.file.path
        load_images
        show_current_image
      end
      d.destroy
    end

    dialog.present
  end

  def load_images
    return unless @directory

    # Load metadata
    meta_path = File.join(@directory, META_FILE)
    if File.exist?(meta_path)
      begin
        @metadata = YAML.safe_load_file(meta_path, permitted_classes: [Symbol]) || {}
        @metadata['pinned'] ||= []
        @metadata['skipped'] ||= []
      rescue StandardError => e
        warn "Failed to load metadata: #{e.message}"
        @metadata = { 'pinned' => [], 'skipped' => [] }
      end
    else
      @metadata = { 'pinned' => [], 'skipped' => [] }
    end

    # Get image files
    @images = Dir.entries(@directory)
                 .select { |f| SUPPORTED_EXTENSIONS.include?(File.extname(f).downcase) }
                 .map { |f| File.join(@directory, f) }

    # Sort by EXIF date then natural sort
    @images.sort_by! do |path|
      exif_date = extract_exif_date(path)
      natural_key = natural_sort_key(File.basename(path))
      [exif_date || Time.new(9999), natural_key]
    end

    @current_index = 0
  end

  def extract_exif_date(path)
    return nil unless %w[.jpg .jpeg .tiff .tif].include?(File.extname(path).downcase)

    begin
      data = Exif::Data.new(File.open(path))
      date_str = data.date_time_original || data.date_time
      return nil unless date_str

      # Parse EXIF date format: "YYYY:MM:DD HH:MM:SS"
      Time.strptime(date_str.to_s, '%Y:%m:%d %H:%M:%S')
    rescue StandardError
      nil
    end
  end

  def natural_sort_key(filename)
    # Split filename into numeric and non-numeric parts for natural sorting
    filename.downcase.split(/(\d+)/).map do |part|
      part.match?(/\d+/) ? part.to_i : part
    end
  end

  def show_current_image
    return if @images.empty?

    path = @images[@current_index]
    return unless File.exist?(path)

    begin
      if @preload_index == @current_index && @preloaded_pixbuf
        pixbuf = @preloaded_pixbuf
      else
        pixbuf = GdkPixbuf::Pixbuf.new(file: path)
      end

      if @fit_to_window
        @image.set_pixbuf(pixbuf)
        @image.can_shrink = true
      else
        # Apply zoom
        scaled_width = (pixbuf.width * @zoom_level).to_i
        scaled_height = (pixbuf.height * @zoom_level).to_i
        scaled = pixbuf.scale_simple(scaled_width, scaled_height, :bilinear)
        @image.set_pixbuf(scaled)
        @image.can_shrink = false
      end

      update_info_bar(path, pixbuf)
      update_status_label(path)
      @window.title = "Image Viewer - #{File.basename(path)}"

      # Preload next image
      preload_next_image
    rescue StandardError => e
      @info_bar.text = "Error loading image: #{e.message}"
    end
  end

  def preload_next_image
    next_idx = find_next_index(@current_index)
    return if next_idx.nil? || next_idx == @preload_index

    Thread.new do
      begin
        path = @images[next_idx]
        @preloaded_pixbuf = GdkPixbuf::Pixbuf.new(file: path)
        @preload_index = next_idx
      rescue StandardError
        @preloaded_pixbuf = nil
        @preload_index = nil
      end
    end
  end

  def update_info_bar(path, pixbuf)
    filename = File.basename(path)
    position = "#{@current_index + 1}/#{@images.size}"
    dimensions = "#{pixbuf.width}x#{pixbuf.height}"
    zoom_info = @fit_to_window ? 'Fit' : "#{(@zoom_level * 100).to_i}%"

    @info_bar.text = "#{filename} | #{position} | #{dimensions} | Zoom: #{zoom_info}"
  end

  def update_status_label(path)
    filename = File.basename(path)
    pinned = @metadata['pinned'].include?(filename)
    skipped = @metadata['skipped'].include?(filename)

    @status_label.remove_css_class('pinned')
    @status_label.remove_css_class('skipped')

    if pinned
      @status_label.text = '📌 PINNED'
      @status_label.add_css_class('pinned')
    elsif skipped
      @status_label.text = '⏭️ SKIPPED'
      @status_label.add_css_class('skipped')
    else
      @status_label.text = ''
    end
  end

  def handle_key_press(keyval, state)
    ctrl = (state & Gdk::ModifierType::CONTROL_MASK) != 0

    case keyval
    when 0xff53 # Right
      navigate_next
    when 0xff51 # Left
      navigate_prev
    when 0x020 # space
      toggle_pinned
    when 0x078, 0x058 # x, X
      mark_skipped
    when 0x02b, 0x03d # plus, equal
      zoom_in
    when 0x02d # minus
      zoom_out
    when 0x030 # 0
      reset_zoom
    when 0x065, 0x045 # e, E
      open_external
    else
      return false
    end

    true
  end

  def navigate_next
    next_idx = find_next_index(@current_index)
    unless next_idx
      # Wrap around to beginning
      next_idx = find_next_index(-1)
    end
    if next_idx
      @current_index = next_idx
      show_current_image
    end
  end

  def navigate_prev
    prev_idx = find_prev_index(@current_index)
    unless prev_idx
      # Wrap around to end
      prev_idx = find_prev_index(@images.size)
    end
    if prev_idx
      @current_index = prev_idx
      show_current_image
    end
  end

  def find_next_index(from_index)
    ((from_index + 1)...@images.size).each do |i|
      return i unless skipped?(@images[i])
    end
    nil
  end

  def find_prev_index(from_index)
    (from_index - 1).downto(0).each do |i|
      return i unless skipped?(@images[i])
    end
    nil
  end

  def skipped?(path)
    filename = File.basename(path)
    @metadata['skipped'].include?(filename)
  end

  def toggle_pinned
    return if @images.empty?

    filename = File.basename(@images[@current_index])
    if @metadata['pinned'].include?(filename)
      @metadata['pinned'].delete(filename)
    else
      @metadata['pinned'] << filename
      @metadata['skipped'].delete(filename)
    end

    save_metadata
    update_status_label(@images[@current_index])
  end

  def mark_skipped
    return if @images.empty?

    filename = File.basename(@images[@current_index])
    unless @metadata['skipped'].include?(filename)
      @metadata['skipped'] << filename
    end
    @metadata['pinned'].delete(filename)

    save_metadata
    navigate_next || show_current_image
  end

  def zoom_in
    @fit_to_window = false
    @zoom_level = [@zoom_level + ZOOM_STEP, MAX_ZOOM].min
    show_current_image
  end

  def zoom_out
    @fit_to_window = false
    @zoom_level = [@zoom_level - ZOOM_STEP, MIN_ZOOM].max
    show_current_image
  end

  def reset_zoom
    @fit_to_window = true
    @zoom_level = 1.0
    show_current_image
  end

  def open_external
    return if @images.empty?

    path = @images[@current_index]
    system('xdg-open', path)
  end

  def save_metadata
    return unless @directory

    meta_path = File.join(@directory, META_FILE)
    begin
      File.write(meta_path, @metadata.to_yaml)
    rescue StandardError => e
      warn "Failed to save metadata: #{e.message}"
    end
  end

  def show_copy_dialog
    dialog = Gtk::FileChooserDialog.new(
      title: 'Select Destination Directory',
      parent: @window,
      action: :select_folder,
      buttons: [['Cancel', :cancel], ['Copy', :accept]]
    )
    dialog.modal = true

    dialog.signal_connect('response') do |d, response|
      if response == Gtk::ResponseType::ACCEPT
        copy_pinned_files(d.file.path)
      end
      d.destroy
    end

    dialog.present
  end

  def copy_pinned_files(dest_dir)
    pinned_files = @metadata['pinned']
    copied = 0

    pinned_files.each do |filename|
      src = File.join(@directory, filename)
      next unless File.exist?(src)

      dest = File.join(dest_dir, filename)
      begin
        FileUtils.cp(src, dest)
        copied += 1
      rescue StandardError => e
        warn "Failed to copy #{filename}: #{e.message}"
      end
    end

    show_message_dialog("Copied #{copied} of #{pinned_files.size} pinned files.")
  end

  def show_message_dialog(message)
    dialog = Gtk::AlertDialog.new(message: message)
    dialog.show(@window)
  end
end

directory = ARGV.first
app = ImageViewer.new(directory)
app.run([])
