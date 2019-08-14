#!/bin/ruby
require 'fileutils'
require_relative '../utility'

$bw_per_gb_by_page_type = {}
$log_dir = nil

LLC_CACHE_LINE_SIZE = 64
def byte_to_MBs(hit_count, time)
  hit_count * LLC_CACHE_LINE_SIZE / (1000000.0 * time)
end

def byte_to_KB(byte)
  byte / 1024
end

def div(a, b)
  return 0 if b == 0
  a / b
end

def format_number(number)
  str = number.to_s
  next_str = nil
  while (true)
    next_str = str.gsub(/(\d+)(\d\d\d)/, '\1,\2')
    break if 0 == (str <=> next_str)
    str = next_str
  end
  str
end

def parse_one_file(file_name)

  remote_read_cold = 0

  ref_count = 0
  page_size = 0
  page_count = 0

  bw_per_gb = 0

  time = 1
  state = :success;
  begin
    file = File.new(file_name, "r")
    file.each do |line|
      case line
      when /([\d,]*)\s+remote_read_COLD/
        remote_read_cold = $1.delete(",").to_i
      when /([\d\.]*)\s+seconds\s+time\s+elapsed/
        time = $1.to_f
      when /.*ref_count=(\d+)/
        ref_count = $1.to_i
      when /.*page_size=(\d+)/
        page_size = $1.to_i
      when /.*page_count=(\d+)/
        page_count = $1.to_i
      end
    end
  rescue StandardError => e
    puts "Warning parse one file: #{e.message}"
    state = :fail
  end

  remote_read_cold = byte_to_MBs(remote_read_cold, time)
  total_byte = page_count * page_size
  bw_per_gb = 1000000000 * div(remote_read_cold, total_byte)

  {:state => state, :ref_count => ref_count,
    :page_size => page_size, :bw_per_gb => bw_per_gb,
    :total_byte => total_byte}

end

def save_result(hash_table, result)
  key = result[:page_size]
  ref_index = result[:ref_count]
  hash_table[key] = [] unless hash_table.has_key? key
  hash_table[key][ref_index] = result
end

def output_bw_per_gb(bw_per_gb_result)
  failed_count = 0

  bw_per_gb_all = 0
  total_all = 0
  count_all = 0

  bw_per_gb_result.each_pair do |page_type, result|
    print "\n%dK-page histogram:\n" % [byte_to_KB(page_type)]
    puts "ref_count    MBps-per-GB         size(KB)\n"
    puts "==========================================\n"

    bw_per_gb_page_type = 0
    total_page_type = 0
    count_page_type = 0

    result.reverse.each do |one_result|
      next if one_result == nil
      if one_result[:state] == :success
        bw_per_gb_page_type += one_result[:bw_per_gb]
        total_page_type += one_result[:total_byte]
        count_page_type += 1

        print "%9d %14.2f %16s\n" \
              % [ one_result[:ref_count], one_result[:bw_per_gb], \
                  format_number(byte_to_KB(one_result[:total_byte])) ]
      else
        failed_count = failed_count + 1
      end
    end

    bw_per_gb_all += bw_per_gb_page_type
    count_all += count_page_type
    total_all += total_page_type

    bw_per_gb_page_type = div(bw_per_gb_page_type, count_page_type)
    total_page_type = byte_to_KB(total_page_type)
    print "%dK-page average BW-per-GB: %.2f\n" \
          % [ byte_to_KB(page_type), bw_per_gb_page_type ]
    print "%dK-page total size:        %s KB\n" \
          % [ byte_to_KB(page_type), format_number(total_page_type) ]
  end

  bw_per_gb_all = div(bw_per_gb_all, count_all)
  total_all = byte_to_KB(total_all)
  print "\nAll average BW-per-GB: %.2f\n" % [ bw_per_gb_all ]
  print "All total size:        %s KB\n" % [ format_number(total_all) ]
  puts "failed count: #{failed_count}" if failed_count > 0

end

def generate_img(bw_per_gb_result, save_dir)
  work_dir = FileUtils.getwd()

  bw_per_gb_result.each_pair do |page_type, result|

    raw_file_name = "bw_per_gb_raw.log"
    begin
      raw_file = File.new(raw_file_name, "w+")
    rescue StandardError => e
      puts "WARNING: generate_img: #{e.message}"
      next
    end

    result.reverse.each do |one_result|
      next if one_result == nil
      if one_result[:state] == :success
        new_line = one_result.values.join(' ')
        new_line += "\n"
        raw_file.write(new_line)
      end
    end
    raw_file.close

    gnuplot_proc = {
        :cmd => work_dir + "/gnuplot_bw_per_gb.sh",
        :out => work_dir + "/gnuplot_bw_per_gb_#{page_type}.out",
        :err => work_dir + "/gnuplot_bw_per_gb_#{page_type}.err",
        :cwd => work_dir,
        :wait => true,
        :pid => nil,
    }
    new_proc(gnuplot_proc)
    if gnuplot_proc[:pid] then
      FileUtils.mv(work_dir + "/bw-per-gb-histogram.png",
                   save_dir + "/bw-per-gb-histogram-#{byte_to_KB(page_type)}K.png")
    else
      puts "Warning: Failed to generate BW-per-GB for page type: #{page_type}"
    end
  end
end

# Start here
begin
  $log_dir = ARGV[0]
  file_name = ARGV[1]
  list_file = File.new(file_name, "r")
  list_file.each do |line|
    result = parse_one_file(line.chomp)
    save_result($bw_per_gb_by_page_type, result)
  end
rescue StandardError => e
  puts "Warning: #{e.message}"
end
if (not $bw_per_gb_by_page_type.empty?)
  output_bw_per_gb($bw_per_gb_by_page_type)
  generate_img($bw_per_gb_by_page_type, $log_dir)
else
  puts "WARNING: No bw-per-gb data."
end
