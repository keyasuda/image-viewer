# frozen_string_literal: true

require 'spec_helper'
require 'image_viewer_core'
require 'tmpdir'
require 'fileutils'

RSpec.describe ImageViewerCore::Metadata do
  let(:metadata) { described_class.new }

  describe '#initialize' do
    it 'starts with empty pinned and skipped lists' do
      expect(metadata.pinned).to eq([])
      expect(metadata.skipped).to eq([])
    end
  end

  describe '#toggle_pinned' do
    it 'adds filename to pinned list' do
      result = metadata.toggle_pinned('test.jpg')
      expect(result).to be true
      expect(metadata.pinned).to include('test.jpg')
    end

    it 'removes filename from pinned list when already pinned' do
      metadata.toggle_pinned('test.jpg')
      result = metadata.toggle_pinned('test.jpg')
      expect(result).to be false
      expect(metadata.pinned).not_to include('test.jpg')
    end

    it 'removes filename from skipped list when pinning' do
      metadata.mark_skipped('test.jpg')
      metadata.toggle_pinned('test.jpg')
      expect(metadata.skipped).not_to include('test.jpg')
    end
  end

  describe '#mark_skipped' do
    it 'adds filename to skipped list' do
      metadata.mark_skipped('test.jpg')
      expect(metadata.skipped).to include('test.jpg')
    end

    it 'removes filename from pinned list' do
      metadata.toggle_pinned('test.jpg')
      metadata.mark_skipped('test.jpg')
      expect(metadata.pinned).not_to include('test.jpg')
    end

    it 'does not duplicate filename in skipped list' do
      metadata.mark_skipped('test.jpg')
      metadata.mark_skipped('test.jpg')
      expect(metadata.skipped.count('test.jpg')).to eq(1)
    end
  end

  describe '#pinned? and #skipped?' do
    it 'returns true for pinned file' do
      metadata.toggle_pinned('test.jpg')
      expect(metadata.pinned?('test.jpg')).to be true
      expect(metadata.skipped?('test.jpg')).to be false
    end

    it 'returns true for skipped file' do
      metadata.mark_skipped('test.jpg')
      expect(metadata.skipped?('test.jpg')).to be true
      expect(metadata.pinned?('test.jpg')).to be false
    end
  end

  describe '.load_from_file and #save_to_file' do
    it 'saves and loads metadata correctly' do
      Dir.mktmpdir do |dir|
        path = File.join(dir, 'imgview_meta.yml')

        metadata.toggle_pinned('pinned1.jpg')
        metadata.toggle_pinned('pinned2.jpg')
        metadata.mark_skipped('skipped1.jpg')
        metadata.save_to_file(path)

        loaded = described_class.load_from_file(path)
        expect(loaded.pinned).to eq(['pinned1.jpg', 'pinned2.jpg'])
        expect(loaded.skipped).to eq(['skipped1.jpg'])
      end
    end

    it 'returns empty metadata for non-existent file' do
      loaded = described_class.load_from_file('/non/existent/path.yml')
      expect(loaded.pinned).to eq([])
      expect(loaded.skipped).to eq([])
    end
  end
end

RSpec.describe ImageViewerCore::ImageList do
  describe '#natural_sort_key' do
    let(:list) { described_class.new }

    it 'sorts filenames naturally' do
      filenames = ['img10.jpg', 'img2.jpg', 'img1.jpg', 'img20.jpg']
      sorted = filenames.sort_by { |f| list.natural_sort_key(f) }
      expect(sorted).to eq(['img1.jpg', 'img2.jpg', 'img10.jpg', 'img20.jpg'])
    end

    it 'handles mixed case' do
      filenames = ['IMG10.jpg', 'img2.jpg', 'Img1.jpg']
      sorted = filenames.sort_by { |f| list.natural_sort_key(f) }
      expect(sorted).to eq(['Img1.jpg', 'img2.jpg', 'IMG10.jpg'])
    end

    it 'handles filenames with multiple number groups' do
      filenames = ['DSC_001_002.jpg', 'DSC_001_001.jpg', 'DSC_002_001.jpg']
      sorted = filenames.sort_by { |f| list.natural_sort_key(f) }
      expect(sorted).to eq(['DSC_001_001.jpg', 'DSC_001_002.jpg', 'DSC_002_001.jpg'])
    end
  end

  describe 'navigation with skipped files' do
    let(:metadata) { ImageViewerCore::Metadata.new }
    let(:list) do
      images = ['/path/img1.jpg', '/path/img2.jpg', '/path/img3.jpg', '/path/img4.jpg', '/path/img5.jpg']
      described_class.new(images, metadata)
    end

    it 'navigates to next non-skipped image' do
      metadata.mark_skipped('img2.jpg')
      list.navigate_next
      expect(File.basename(list.current)).to eq('img3.jpg')
    end

    it 'skips multiple consecutive skipped images' do
      metadata.mark_skipped('img2.jpg')
      metadata.mark_skipped('img3.jpg')
      list.navigate_next
      expect(File.basename(list.current)).to eq('img4.jpg')
    end

    it 'wraps around to beginning when at end' do
      4.times { list.navigate_next }
      expect(File.basename(list.current)).to eq('img5.jpg')
      list.navigate_next
      expect(File.basename(list.current)).to eq('img1.jpg')
    end

    it 'wraps around to end when at beginning' do
      list.navigate_prev
      expect(File.basename(list.current)).to eq('img5.jpg')
    end

    it 'wraps around skipping skipped files' do
      metadata.mark_skipped('img5.jpg')
      metadata.mark_skipped('img4.jpg')
      # From img1: next goes to img2, then img3, then wraps to img1
      list.navigate_next # img1 -> img2
      list.navigate_next # img2 -> img3
      expect(File.basename(list.current)).to eq('img3.jpg')
      list.navigate_next # img3 -> img1 (skips img4, img5, wraps)
      expect(File.basename(list.current)).to eq('img1.jpg')
    end
  end

  describe '.from_directory' do
    it 'loads images from directory' do
      Dir.mktmpdir do |dir|
        FileUtils.touch(File.join(dir, 'test1.jpg'))
        FileUtils.touch(File.join(dir, 'test2.png'))
        FileUtils.touch(File.join(dir, 'test3.txt')) # Should be ignored

        list = described_class.from_directory(dir)
        expect(list.size).to eq(2)
        expect(list.images.map { |p| File.basename(p) }).to contain_exactly('test1.jpg', 'test2.png')
      end
    end

    it 'returns empty list for non-existent directory' do
      list = described_class.from_directory('/non/existent/dir')
      expect(list.empty?).to be true
    end

    it 'starts at specified initial file' do
      Dir.mktmpdir do |dir|
        FileUtils.touch(File.join(dir, 'img1.jpg'))
        FileUtils.touch(File.join(dir, 'img2.jpg'))
        FileUtils.touch(File.join(dir, 'img3.jpg'))

        initial_file = File.join(dir, 'img2.jpg')
        list = described_class.from_directory(dir, nil, initial_file: initial_file)
        expect(File.basename(list.current)).to eq('img2.jpg')
      end
    end
  end

  describe '#jump_to_file' do
    it 'jumps to specified file' do
      Dir.mktmpdir do |dir|
        FileUtils.touch(File.join(dir, 'img1.jpg'))
        FileUtils.touch(File.join(dir, 'img2.jpg'))
        FileUtils.touch(File.join(dir, 'img3.jpg'))

        list = described_class.from_directory(dir)
        expect(File.basename(list.current)).to eq('img1.jpg')

        result = list.jump_to_file(File.join(dir, 'img3.jpg'))
        expect(result).to be true
        expect(File.basename(list.current)).to eq('img3.jpg')
      end
    end

    it 'returns false for non-existent file' do
      Dir.mktmpdir do |dir|
        FileUtils.touch(File.join(dir, 'img1.jpg'))

        list = described_class.from_directory(dir)
        result = list.jump_to_file(File.join(dir, 'nonexistent.jpg'))
        expect(result).to be false
      end
    end
  end
end

RSpec.describe ImageViewerCore::FileCopier do
  describe '.copy_pinned' do
    it 'copies pinned files to destination' do
      Dir.mktmpdir do |src_dir|
        Dir.mktmpdir do |dest_dir|
          # Create source files
          FileUtils.touch(File.join(src_dir, 'pinned1.jpg'))
          FileUtils.touch(File.join(src_dir, 'pinned2.jpg'))
          FileUtils.touch(File.join(src_dir, 'not_pinned.jpg'))

          metadata = ImageViewerCore::Metadata.new
          metadata.toggle_pinned('pinned1.jpg')
          metadata.toggle_pinned('pinned2.jpg')

          result = described_class.copy_pinned(metadata, src_dir, dest_dir)

          expect(result[:copied]).to eq(2)
          expect(result[:total]).to eq(2)
          expect(File.exist?(File.join(dest_dir, 'pinned1.jpg'))).to be true
          expect(File.exist?(File.join(dest_dir, 'pinned2.jpg'))).to be true
          expect(File.exist?(File.join(dest_dir, 'not_pinned.jpg'))).to be false
        end
      end
    end

    it 'handles missing source files gracefully' do
      Dir.mktmpdir do |src_dir|
        Dir.mktmpdir do |dest_dir|
          metadata = ImageViewerCore::Metadata.new
          metadata.toggle_pinned('missing.jpg')

          result = described_class.copy_pinned(metadata, src_dir, dest_dir)

          expect(result[:copied]).to eq(0)
          expect(result[:total]).to eq(1)
        end
      end
    end
  end
end
