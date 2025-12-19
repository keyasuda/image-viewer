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

    # Drag source and context menu for image
    setup_drag_source
    setup_context_menu

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

  def setup_drag_source
    drag_source = Gtk::DragSource.new
    drag_source.actions = Gdk::DragAction::COPY

    drag_source.signal_connect('prepare') do |_source, _x, _y|
      next nil if @image_list.nil? || @image_list.empty?

      # Set drag icon
      if @current_pixbuf
        icon_size = 64
        scale = [icon_size.to_f / @current_pixbuf.width, icon_size.to_f / @current_pixbuf.height].min
        icon_width = (@current_pixbuf.width * scale).to_i
        icon_height = (@current_pixbuf.height * scale).to_i
        icon = @current_pixbuf.scale_simple(icon_width, icon_height, :bilinear)
        texture = Gdk::Texture.new(icon)
        drag_source.set_icon(texture, icon_width / 2, icon_height / 2)
      end

      path = @image_list.current
      file = Gio::File.new_for_path(path)
      uri = file.uri + "\r\n"
      bytes = GLib::Bytes.new(uri)
      Gdk::ContentProvider.new('text/uri-list', bytes)
    end

    @image.add_controller(drag_source)
  end

  def setup_context_menu
    # Create a click controller to detect right-clicks
    click_ctrl = Gtk::GestureClick.new
    click_ctrl.button = 3  # Right mouse button

    click_ctrl.signal_connect('pressed') do |controller, _n_press, x, y|
      menu = create_context_menu
      menu.pointing_to = Gdk::Rectangle.new(x.to_i, y.to_i, 1, 1)
      menu.parent = @image
      menu.popup
    end

    @image.add_controller(click_ctrl)
  end

  def create_context_menu
    menu = Gtk::PopoverMenu.new

    # Create section for navigation actions
    nav_section = Gio::Menu.new
    nav_section.append('Next Image', 'app.next')
    nav_section.append('Previous Image', 'app.prev')
    nav_section.append('Next Pinned', 'app.next_pinned')
    nav_section.append('Previous Pinned', 'app.prev_pinned')

    # Create section for pin/skip actions
    pin_section = Gio::Menu.new
    pin_section.append('Toggle Pinned', 'app.toggle_pinned')
    pin_section.append('Mark as Skipped', 'app.mark_skipped')
    pin_section.append('Clear All Pinned', 'app.clear_pinned')

    # Create section for zoom actions
    zoom_section = Gio::Menu.new
    zoom_section.append('Zoom In', 'app.zoom_in')
    zoom_section.append('Zoom Out', 'app.zoom_out')
    zoom_section.append('Reset Zoom', 'app.reset_zoom')

    # Create section for other actions
    other_section = Gio::Menu.new
    other_section.append('Open With...', 'app.open_external')
    other_section.append('Move to Trash', 'app.move_to_trash')

    # Add all sections to the menu model
    menu_model = Gio::Menu.new
    menu_model.append_section(nil, nav_section)
    menu_model.append_section(nil, pin_section)
    menu_model.append_section(nil, zoom_section)
    menu_model.append_section(nil, other_section)

    menu.menu_model = menu_model

    # Connect actions to their respective handlers
    action_group = Gio::SimpleActionGroup.new
    @window.insert_action_group('app', action_group)

    # Navigation actions
    add_action(action_group, 'next') { navigate_next }
    add_action(action_group, 'prev') { navigate_prev }
    add_action(action_group, 'next_pinned') { navigate_next_pinned }
    add_action(action_group, 'prev_pinned') { navigate_prev_pinned }

    # Pin/skip actions
    add_action(action_group, 'toggle_pinned') { toggle_pinned }
    add_action(action_group, 'mark_skipped') { mark_skipped }
    add_action(action_group, 'clear_pinned') { show_clear_pinned_dialog }

    # Zoom actions
    add_action(action_group, 'zoom_in') { zoom_in }
    add_action(action_group, 'zoom_out') { zoom_out }
    add_action(action_group, 'reset_zoom') { reset_zoom }

    # Other actions
    add_action(action_group, 'open_external') { open_external }
    add_action(action_group, 'move_to_trash') { show_trash_confirmation }

    menu
  end

  def add_action(action_group, name, &block)
    action = Gio::SimpleAction.new(name, nil)
    action.signal_connect('activate') { |a, p| block.call }
    action_group.add_action(action)
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

    if @initial_file
      # Lazy load: Show initial file immediately
      @image_list = ImageViewerCore::ImageList.new([@initial_file], @metadata)
      
      # Load full list in background
      Thread.new do
        full_list = ImageViewerCore::ImageList.from_directory(@directory, @metadata, initial_file: @initial_file)
        GLib::Idle.add do
          update_image_list(full_list)
          false # Stop idle handler
        end
      end
    else
      # Directory mode: Load everything immediately
      @image_list = ImageViewerCore::ImageList.from_directory(@directory, @metadata)
    end
  end

  def update_image_list(new_list)
    return if new_list.nil? || new_list.empty?

    # Preserve current file selection if possible
    current_file = @image_list.current
    @image_list = new_list
    
    # Try to keep pointing to the same file, or fallback to what the new list has
    if current_file
      @image_list.jump_to_file(current_file)
    end

    # Update UI
    show_current_image
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
        pixbuf = apply_exif_rotation(pixbuf, path)
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
        pixbuf = GdkPixbuf::Pixbuf.new(file: path)
        @preloaded_pixbuf = apply_exif_rotation(pixbuf, path)
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

  def apply_exif_rotation(pixbuf, path)
    return pixbuf unless ['.jpg', '.jpeg', '.tiff', '.tif'].include?(File.extname(path).downcase)

    begin
      # Fix: Open with File.open to handle non-ASCII paths correctly, and use block to auto-close
      orientation = File.open(path) do |f|
        data = Exif::Data.new(f)
        data.orientation
      end
      
      case orientation
      when 2 # Mirror horizontal
        pixbuf = pixbuf.flip(true)
      when 3 # Rotate 180
        pixbuf = pixbuf.rotate_simple(GdkPixbuf::PixbufRotation::UPSIDEDOWN)
      when 4 # Mirror vertical
        pixbuf = pixbuf.flip(false)
      when 5 # Mirror horizontal and rotate 270 CW
        pixbuf = pixbuf.rotate_simple(GdkPixbuf::PixbufRotation::CLOCKWISE).flip(true)
      when 6 # Rotate 90 CW
        pixbuf = pixbuf.rotate_simple(GdkPixbuf::PixbufRotation::CLOCKWISE)
      when 7 # Mirror horizontal and rotate 90 CW
        pixbuf = pixbuf.rotate_simple(GdkPixbuf::PixbufRotation::COUNTERCLOCKWISE).flip(true)
      when 8 # Rotate 270 CW
        pixbuf = pixbuf.rotate_simple(GdkPixbuf::PixbufRotation::COUNTERCLOCKWISE)
      end
    rescue StandardError
      # Ignore EXIF errors (no EXIF data, malformed, etc.)
    end

    pixbuf
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
    shift = (state & Gdk::ModifierType::SHIFT_MASK) != 0

    case keyval
    when 0xff53 # Right
      if ctrl
        navigate_next_pinned
      elsif shift
        navigate_forward(10)
      else
        navigate_next
      end
    when 0xff51 # Left
      if ctrl
        navigate_prev_pinned
      elsif shift
        navigate_backward(10)
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
    when 0xffff # Delete
      show_trash_confirmation
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

  def navigate_forward(steps)
    return if @image_list.nil? || @image_list.empty?

    if @image_list.navigate_forward(steps)
      show_current_image
    end
  end

  def navigate_backward(steps)
    return if @image_list.nil? || @image_list.empty?

    if @image_list.navigate_backward(steps)
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

  def show_trash_confirmation
    return if @image_list.nil? || @image_list.empty?

    current_file = @image_list.current
    filename = File.basename(current_file)

    dialog = Gtk::MessageDialog.new(
      parent: @window,
      flags: Gtk::DialogFlags::MODAL | Gtk::DialogFlags::DESTROY_WITH_PARENT,
      type: :question,
      buttons: :yes_no,
      message: "Move '#{filename}' to trash?"
    )

    dialog.signal_connect('response') do |d, response|
      if response == Gtk::ResponseType::YES
        move_to_trash(current_file)
      end
      d.destroy
    end

    dialog.present
  end

  def move_to_trash(path)
    return unless File.exist?(path)

    filename = File.basename(path)

    # Move file to trash using gio trash
    success = system('gio', 'trash', path)

    if success
      # Remove from metadata
      @metadata.remove_file(filename) if @metadata

      # Remove from image list and navigate to next
      @image_list.remove_current

      # Save metadata
      save_metadata if @metadata

      # Show next image or close if no images left
      if @image_list.empty?
        show_message_dialog("No more images in the directory.")
        @window.close
      else
        show_current_image
      end
    else
      show_message_dialog("Failed to move file to trash: #{filename}")
    end
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

  def save_metadata(force: false)
    return unless @directory && @metadata

    meta_path = File.join(@directory, ImageViewerCore::META_FILE)
    @metadata.save_to_file(meta_path, force: force)
  rescue ImageViewerCore::ConcurrentModificationError
    dialog = Gtk::MessageDialog.new(
      parent: @window,
      flags: Gtk::DialogFlags::MODAL | Gtk::DialogFlags::DESTROY_WITH_PARENT,
      type: :question,
      buttons: :yes_no,
      message: "Metadata file has been modified by another process.\nOverwrite?"
    )

    dialog.signal_connect('response') do |d, response|
      if response == Gtk::ResponseType::YES
        save_metadata(force: true)
      end
      d.destroy
    end

    dialog.present
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
        dest_dir = d.file.path
        existing = ImageViewerCore::FileCopier.check_existing(@metadata, dest_dir)

        if existing.empty?
          copy_pinned_files(dest_dir)
        else
          show_overwrite_confirmation(dest_dir, existing)
        end
      end
      d.destroy
    end

    dialog.present
  end

  def show_overwrite_confirmation(dest_dir, existing)
    message = "The following files already exist in the destination folder and will be overwritten:\n\n"
    message += existing.take(5).join("\n")
    message += "\n...and #{existing.size - 5} more" if existing.size > 5
    message += "\n\nDo you want to continue?"

    dialog = Gtk::MessageDialog.new(
      parent: @window,
      flags: Gtk::DialogFlags::MODAL | Gtk::DialogFlags::DESTROY_WITH_PARENT,
      type: :warning,
      buttons: :yes_no,
      message: message
    )

    dialog.signal_connect('response') do |d, response|
      if response == Gtk::ResponseType::YES
        copy_pinned_files(dest_dir)
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
