#!/usr/bin/env ruby
# frozen_string_literal: true

require 'bundler/setup'
require 'gtk4'
require 'exif'
require 'yaml'
require 'fileutils'
require_relative 'lib/image_viewer_core'

class ImageViewer < Gtk::Application
  ZOOM_STEP = 0.1
  MIN_ZOOM = 0.1
  MAX_ZOOM = 10.0

  def initialize(path = nil)
    super('com.example.imageviewer', :non_unique)
    @zoom_level = 1.0
    @fit_to_window = true
    @initial_file = nil

    # Determine if path is a file or directory
    if path && File.file?(path)
      @directory = File.dirname(path)
      @initial_file = File.expand_path(path)
    elsif path && File.directory?(path)
      @directory = path
    else
      @directory = nil
    end

    @metadata = nil
    @image_list = nil
    @preloaded_pixbuf = nil
    @preload_index = nil
    @current_pixbuf = nil

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
    meta_path = File.join(@directory, ImageViewerCore::META_FILE)
    @metadata = ImageViewerCore::Metadata.load_from_file(meta_path)

    # Load and sort image list, jump to initial file if specified
    @image_list = ImageViewerCore::ImageList.from_directory(@directory, @metadata, initial_file: @initial_file)
  end

  def show_current_image
    return if @image_list.nil? || @image_list.empty?

    path = @image_list.current
    return unless File.exist?(path)

    begin
      if @preload_index == @image_list.current_index && @preloaded_pixbuf
        pixbuf = @preloaded_pixbuf
      else
        pixbuf = GdkPixbuf::Pixbuf.new(file: path)
      end

      @current_pixbuf = pixbuf

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
    next_idx = @image_list.find_next_index(@image_list.current_index)
    return if next_idx.nil? || next_idx == @preload_index

    Thread.new do
      begin
        path = @image_list.images[next_idx]
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
    position = "#{@image_list.current_index + 1}/#{@image_list.size}"
    dimensions = "#{pixbuf.width}x#{pixbuf.height}"
    zoom_info = @fit_to_window ? 'Fit' : "#{(@zoom_level * 100).to_i}%"
    pin_skip_info = "📌#{@metadata.pinned_count} ⏭️#{@metadata.skipped_count}"

    @info_bar.text = "#{filename} | #{position} | #{dimensions} | Zoom: #{zoom_info} | #{pin_skip_info}"
  end

  def update_status_label(path)
    filename = File.basename(path)
    pinned = @metadata.pinned?(filename)
    skipped = @metadata.skipped?(filename)

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
      if ctrl
        navigate_next_pinned
      else
        navigate_next
      end
    when 0xff51 # Left
      if ctrl
        navigate_prev_pinned
      else
        navigate_prev
      end
    when 0x020 # space
      if ctrl
        show_clear_pinned_dialog
      else
        toggle_pinned
      end
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
    when 0xff1b # Escape
      @window.close
    else
      return false
    end

    true
  end

  def navigate_next
    return if @image_list.nil? || @image_list.empty?

    if @image_list.navigate_next
      show_current_image
    end
  end

  def navigate_prev
    return if @image_list.nil? || @image_list.empty?

    if @image_list.navigate_prev
      show_current_image
    end
  end

  def navigate_next_pinned
    return if @image_list.nil? || @image_list.empty?

    if @image_list.navigate_next_pinned
      show_current_image
    end
  end

  def navigate_prev_pinned
    return if @image_list.nil? || @image_list.empty?

    if @image_list.navigate_prev_pinned
      show_current_image
    end
  end

  def toggle_pinned
    return if @image_list.nil? || @image_list.empty?

    filename = File.basename(@image_list.current)
    @metadata.toggle_pinned(filename)

    save_metadata
    update_status_label(@image_list.current)
    update_info_bar(@image_list.current, @current_pixbuf) if @current_pixbuf
  end

  def mark_skipped
    return if @image_list.nil? || @image_list.empty?

    filename = File.basename(@image_list.current)
    @metadata.mark_skipped(filename)

    save_metadata
    navigate_next || show_current_image
  end

  def show_clear_pinned_dialog
    return if @metadata.nil?
    return if @metadata.pinned_count == 0

    dialog = Gtk::MessageDialog.new(
      parent: @window,
      flags: Gtk::DialogFlags::MODAL | Gtk::DialogFlags::DESTROY_WITH_PARENT,
      type: :question,
      buttons: :yes_no,
      message: "Clear all #{@metadata.pinned_count} pinned images?"
    )

    dialog.signal_connect('response') do |d, response|
      if response == Gtk::ResponseType::YES
        @metadata.clear_pinned
        save_metadata
        update_status_label(@image_list.current) if @image_list&.current
        update_info_bar(@image_list.current, @current_pixbuf) if @image_list&.current && @current_pixbuf
      end
      d.destroy
    end

    dialog.present
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
    return if @image_list.nil? || @image_list.empty?

    path = @image_list.current
    file = Gio::File.new_for_path(path)
    content_type = Gio::ContentType.guess(path, nil).first

    # Get list of apps that can open this content type
    apps = Gio::AppInfo.get_all_for_type(content_type)
    return if apps.empty?

    # Create a simple dialog with app list
    dialog = Gtk::Dialog.new(
      title: 'Open With',
      parent: @window,
      flags: Gtk::DialogFlags::MODAL | Gtk::DialogFlags::DESTROY_WITH_PARENT
    )
    dialog.add_button('Cancel', Gtk::ResponseType::CANCEL)
    dialog.add_button('Open', Gtk::ResponseType::OK)
    dialog.set_default_size(300, 400)

    # Create scrolled list of applications
    scrolled = Gtk::ScrolledWindow.new
    scrolled.vexpand = true
    scrolled.hexpand = true

    listbox = Gtk::ListBox.new
    listbox.selection_mode = :single

    rows = []
    apps.each do |app|
      row = Gtk::ListBoxRow.new
      box = Gtk::Box.new(:horizontal, 10)
      box.margin_start = 10
      box.margin_end = 10
      box.margin_top = 5
      box.margin_bottom = 5

      label = Gtk::Label.new(app.name)
      label.xalign = 0
      box.append(label)

      row.child = box
      listbox.append(row)
      rows << row
    end

    # Select first item by default
    listbox.select_row(rows.first) if rows.any?

    # Double-click to open
    listbox.signal_connect('row-activated') do |_listbox, row|
      idx = rows.index(row)
      if idx
        app_info = apps[idx]
        app_info.launch([file], nil) if app_info
        dialog.destroy
      end
    end

    scrolled.child = listbox
    dialog.content_area.append(scrolled)

    dialog.signal_connect('response') do |d, response|
      if response == Gtk::ResponseType::OK
        selected_row = listbox.selected_row
        if selected_row
          idx = rows.index(selected_row)
          app_info = apps[idx] if idx
          app_info.launch([file], nil) if app_info
        end
      end
      d.destroy
    end

    dialog.present
  end

  def save_metadata
    return unless @directory && @metadata

    meta_path = File.join(@directory, ImageViewerCore::META_FILE)
    @metadata.save_to_file(meta_path)
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
    result = ImageViewerCore::FileCopier.copy_pinned(@metadata, @directory, dest_dir)
    show_message_dialog("Copied #{result[:copied]} of #{result[:total]} pinned files.")
  end

  def show_message_dialog(message)
    dialog = Gtk::AlertDialog.new(message: message)
    dialog.show(@window)
  end
end

directory = ARGV.first
app = ImageViewer.new(directory)
app.run([])
