# frozen_string_literal: true

require 'yaml'
require 'fileutils'
require 'digest'

# Core logic for image viewer, separated from GUI
module ImageViewerCore
  SUPPORTED_EXTENSIONS = %w[.jpg .jpeg .png .webp .tiff .tif .bmp].freeze
  META_FILE = 'imgview_meta.yml'

  class ConcurrentModificationError < StandardError; end

  # Metadata management
  class Metadata
    attr_reader :pinned, :skipped
    attr_accessor :source_hash

    def initialize
      @pinned = []
      @skipped = []
      @source_hash = nil
    end

    def self.load_from_file(path)
      metadata = new
      return metadata unless File.exist?(path)

      begin
        content = File.read(path)
        metadata.source_hash = Digest::SHA256.hexdigest(content)
        data = YAML.safe_load(content, permitted_classes: [Symbol]) || {}
        metadata.instance_variable_set(:@pinned, Array(data['pinned']))
        metadata.instance_variable_set(:@skipped, Array(data['skipped']))
      rescue StandardError => e
        warn "Failed to load metadata: #{e.message}"
      end
      metadata
    end

    def save_to_file(path, force: false)
      if !force && File.exist?(path)
        current_content = File.read(path)
        current_hash = Digest::SHA256.hexdigest(current_content)
        
        if @source_hash && current_hash != @source_hash
          raise ConcurrentModificationError, "Metadata file has been modified by another process"
        end
      end

      data = {
        'pinned' => @pinned,
        'skipped' => @skipped
      }
      yaml_content = data.to_yaml
      File.write(path, yaml_content)
      @source_hash = Digest::SHA256.hexdigest(yaml_content)
      true
    rescue ConcurrentModificationError
      raise
    rescue StandardError => e
      warn "Failed to save metadata: #{e.message}"
      false
    end

    def pinned?(filename)
      @pinned.include?(filename)
    end

    def skipped?(filename)
      @skipped.include?(filename)
    end

    def toggle_pinned(filename)
      if @pinned.include?(filename)
        @pinned.delete(filename)
        false
      else
        @pinned << filename
        @skipped.delete(filename)
        true
      end
    end

    def mark_skipped(filename)
      @skipped << filename unless @skipped.include?(filename)
      @pinned.delete(filename)
    end

    def unmark_skipped(filename)
      @skipped.delete(filename)
    end

    def pinned_count
      @pinned.size
    end

    def skipped_count
      @skipped.size
    end

    def clear_pinned
      @pinned.clear
    end

    def remove_file(filename)
      @pinned.delete(filename)
      @skipped.delete(filename)
    end
  end

  # Image list management and sorting
  class ImageList
    attr_reader :images, :current_index

    def initialize(images = [], metadata = nil)
      @images = images
      @metadata = metadata || Metadata.new
      @current_index = 0
    end

    def self.from_directory(directory, metadata = nil, initial_file: nil)
      return new([], metadata) unless directory && File.directory?(directory)

      files = Dir.entries(directory)
                 .select { |f| SUPPORTED_EXTENSIONS.include?(File.extname(f).downcase) }
                 .map { |f| File.join(directory, f) }

      list = new(files, metadata)
      list.sort_by_exif_and_name
      list.jump_to_file(initial_file) if initial_file
      list
    end

    def sort_by_exif_and_name
      @images.sort_by! do |path|
        exif_date = extract_exif_date(path)
        natural_key = natural_sort_key(File.basename(path))
        [exif_date || Time.new(9999), natural_key]
      end
    end

    def jump_to_file(filepath)
      return false if filepath.nil?

      idx = @images.index(filepath)
      idx ||= @images.index { |p| File.basename(p) == File.basename(filepath) }
      if idx
        @current_index = idx
        true
      else
        false
      end
    end

    def current
      @images[@current_index]
    end

    def size
      @images.size
    end

    def empty?
      @images.empty?
    end

    def navigate_next
      return nil if @images.empty?

      next_idx = find_next_index(@current_index)
      next_idx ||= find_next_index(-1) # Wrap around
      if next_idx
        @current_index = next_idx
        current
      end
    end

    def navigate_prev
      return nil if @images.empty?

      prev_idx = find_prev_index(@current_index)
      prev_idx ||= find_prev_index(@images.size) # Wrap around
      if prev_idx
        @current_index = prev_idx
        current
      end
    end

    def navigate_forward(steps)
      return nil if @images.empty?

      steps.times do
        next_idx = find_next_index(@current_index)
        next_idx ||= find_next_index(-1) # Wrap around
        @current_index = next_idx if next_idx
      end
      current
    end

    def navigate_backward(steps)
      return nil if @images.empty?

      steps.times do
        prev_idx = find_prev_index(@current_index)
        prev_idx ||= find_prev_index(@images.size) # Wrap around
        @current_index = prev_idx if prev_idx
      end
      current
    end

    def find_next_index(from_index)
      ((from_index + 1)...@images.size).each do |i|
        return i unless @metadata.skipped?(File.basename(@images[i]))
      end
      nil
    end

    def find_prev_index(from_index)
      (from_index - 1).downto(0).each do |i|
        return i unless @metadata.skipped?(File.basename(@images[i]))
      end
      nil
    end

    def navigate_next_pinned
      return nil if @images.empty?

      next_idx = find_next_pinned_index(@current_index)
      next_idx ||= find_next_pinned_index(-1) # Wrap around
      if next_idx
        @current_index = next_idx
        current
      end
    end

    def navigate_prev_pinned
      return nil if @images.empty?

      prev_idx = find_prev_pinned_index(@current_index)
      prev_idx ||= find_prev_pinned_index(@images.size) # Wrap around
      if prev_idx
        @current_index = prev_idx
        current
      end
    end

    def find_next_pinned_index(from_index)
      ((from_index + 1)...@images.size).each do |i|
        return i if @metadata.pinned?(File.basename(@images[i]))
      end
      nil
    end

    def find_prev_pinned_index(from_index)
      (from_index - 1).downto(0).each do |i|
        return i if @metadata.pinned?(File.basename(@images[i]))
      end
      nil
    end

    def extract_exif_date(path)
      return nil unless %w[.jpg .jpeg .tiff .tif].include?(File.extname(path).downcase)

      begin
        require 'exif'
        data = Exif::Data.new(File.open(path))
        date_str = data.date_time_original || data.date_time
        return nil unless date_str

        Time.strptime(date_str.to_s, '%Y:%m:%d %H:%M:%S')
      rescue StandardError
        nil
      end
    end

    def natural_sort_key(filename)
      filename.downcase.split(/(\d+)/).map do |part|
        part.match?(/\d+/) ? part.to_i : part
      end
    end

    def remove_current
      return if @images.empty?

      @images.delete_at(@current_index)
      
      # Adjust current_index if we deleted the last item
      if @current_index >= @images.size && !@images.empty?
        @current_index = @images.size - 1
      end
    end
  end

  # Copy pinned files to destination
  class FileCopier
    def self.check_existing(metadata, dest_dir)
      existing = []
      metadata.pinned.each do |filename|
        dest = File.join(dest_dir, filename)
        existing << filename if File.exist?(dest)
      end
      existing
    end

    def self.copy_pinned(metadata, source_dir, dest_dir)
      copied = 0
      errors = []

      metadata.pinned.each do |filename|
        src = File.join(source_dir, filename)
        next unless File.exist?(src)

        dest = File.join(dest_dir, filename)
        begin
          FileUtils.cp(src, dest)
          copied += 1
        rescue StandardError => e
          errors << { filename: filename, error: e.message }
        end
      end

      { copied: copied, total: metadata.pinned.size, errors: errors }
    end
  end
end
