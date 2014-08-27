#!/usr/bin/ruby
#
# This is a little smarter than a shell script.
#
#
require 'mcollective'
include MCollective::RPC
require 'pp'

options = rpcoptions do |parser, options|
	parser.define_head "RedHat/Centos System Updater"
	parser.banner = "Usage: patch.rb [options] [filters]"

	parser.on('--bw', '--plain', 'Do not use colors') do |v|
		options[:bw] = v
	end
	parser.on('--all', '--all-hosts', 'Allow patching of all discovered hosts (no filters)') do |v|
		options[:allhosts] = v
	end
end

# FIXME: There is probably a better way to do this
if options.include?(:bw)
	# Define these as empty
	class String
		def black;          "#{self}" end
		def red;            "#{self}" end
		def green;          "#{self}" end
		def brown;          "#{self}" end
		def blue;           "#{self}" end
		def magenta;        "#{self}" end
		def cyan;           "#{self}" end
		def gray;           "#{self}" end
		def bg_black;       "#{self}" end
		def bg_red;         "#{self}" end
		def bg_green;       "#{self}" end
		def bg_brown;       "#{self}" end
		def bg_blue;        "#{self}" end
		def bg_magenta;     "#{self}" end
		def bg_cyan;        "#{self}" end
		def bg_gray;        "#{self}" end
		def bold;           "#{self}" end
		def reverse_color;  "#{self}" end
	end
else
	# To make pretty output
	class String
		def black;          "\033[30m#{self}\033[0m" end
		def red;            "\033[31m#{self}\033[0m" end
		def green;          "\033[32m#{self}\033[0m" end
		def brown;          "\033[33m#{self}\033[0m" end
		def blue;           "\033[34m#{self}\033[0m" end
		def magenta;        "\033[35m#{self}\033[0m" end
		def cyan;           "\033[36m#{self}\033[0m" end
		def gray;           "\033[37m#{self}\033[0m" end
		def bg_black;       "\033[40m#{self}\033[0m" end
		def bg_red;         "\033[41m#{self}\033[0m" end
		def bg_green;       "\033[42m#{self}\033[0m" end
		def bg_brown;       "\033[43m#{self}\033[0m" end
		def bg_blue;        "\033[44m#{self}\033[0m" end
		def bg_magenta;     "\033[45m#{self}\033[0m" end
		def bg_cyan;        "\033[46m#{self}\033[0m" end
		def bg_gray;        "\033[47m#{self}\033[0m" end
		def bold;           "\033[1m#{self}\033[22m" end
		def reverse_color;  "\033[7m#{self}\033[27m" end
	end
end

yumrpc = rpcclient("yum", :options => options)

# Cache request for 15 minutes, in case of down nodes
yumrpc.ttl = 900

# Run 10 nodes at a time, sleeping 5 seconds between batches.
yumrpc.batch_size = 10
yumrpc.batch_sleep_time = 5

# Don't run the countdown bar while finding matching hosts.
yumrpc.discover :verbose => false
yumrpc.progress = false

# Make sure there is a filter
if !options.include?(:allhosts)
    if yumrpc.filter.empty? or yumrpc.filter == {"compound"=>[], "agent"=>["yum"], "fact"=>[], "cf_class"=>[], "identity"=>[]}
        abort("EE: You must provide a host filter!".bold.red)
    end
end

# The list of systems flagged for a reboot (kernel update):
rebootlist=[]
errorlist=[]

# Status output
puts("II: Finding matching hosts...")

# Run a manual discovery so that we can keep the results
hostlist=yumrpc.discover

if hostlist.empty?
	abort("EE: No hosts found!".bold.red)
elsif hostlist.count > 30
	printf("WW:".brown+" Found more than 30 hosts (%s total). Continue? (y/n) ".bold, hostlist.count)
	input = gets.strip
	if input != "y" and input != "Y"
		abort("EE: Aborting at user request.".bold.red)
	end
else
	printf("II: Found %s host(s).\n",hostlist.count)
end

hostcount=0

# Run check-update on everything in hostlist:
yumrpc.custom_request("check-update",{},hostlist,yumrpc.filter) do |resp|
	# If yum exited with an error, remove the host from the list.
	if resp[:body][:statuscode] != 0
		printf("EE:".bold.red+" %s: ERROR: %s\n", resp[:senderid].bold,resp[:body][:statusmsg])
		errorlist.push(resp[:senderid])
		hostlist.delete(resp[:senderid])
	else
		# If there are no packages to update, remove the host from the list
		if resp[:body][:data][:outdated_packages].empty?
			printf("OK:".bold.green+" %s: Up to date\n",resp[:senderid].bold)
			hostlist.delete(resp[:senderid])
		else
			printf("II: %s: ", resp[:senderid].bold)
			resp[:body][:data][:outdated_packages].each do |package|
				if package[:package].include? "kernel"
					if !rebootlist.include?(resp[:senderid])
						rebootlist.push(resp[:senderid])
					end
				end
				printf("%s, ", package[:package])
			end
			hostcount += 1
			printf("\n")
		end
	end
end

# Notify user of hosts that may need a reboot
if !rebootlist.empty?
	printf("WW:".bold.brown+" Reboot list:\n")
	rebootlist.each do |reboot|
		printf("WW:".bold.brown+"    %s\n",reboot)
	end
end

# List systems that had errors on check-update
if !errorlist.empty?
	printf("EE:".bold.red+" Errored Hosts:\n")
	errorlist.each do |error|
		printf("EE:".bold.red+"    %s\n",error)
	end
end

if hostcount == 0
	abort("EE: No hosts need updates. Aborting.".bold.red)
else
	printf("II: %s host(s) need to be updated.\n",hostcount)
end

printf "II: Do you want to patch these systems? (y/n only): "
input = gets.strip
if input != "y" and input != "Y"
	abort("EE: Aborting at user request.".bold.red)
end

errorpatch=[]
successpatch=0

# Do the patching by calling the 'update' RPC.
# Intentionally NOT rerunning discovery here. Using the existing response list,
# after removing hosts with errors or 0 updates.

yumrpc.custom_request("update",{},hostlist,yumrpc.filter) do |resp|
	# Check for errors in status or yum exit code
	if resp[:body][:statuscode] != 0 or resp[:body][:data][:exitcode] != 0
		printf("EE:".bold.red+" %s: %s (exit %s), msg %s\n",
		       resp[:senderid].bold,
		       resp[:body][:statuscode],
		       resp[:body][:data][:exitcode],
		       resp[:body][:statusmsg])
		# This doesn't print much most of the time, but when it does it is error messages
		resp[:body][:data][:output].each do |line|
			printf("EE:  %s".bold.red, line)
		end
		puts "\n"
		errorpatch.push(resp[:senderid])
	else
		printf("II: %s: %s (exit %s), msg %s\n",resp[:senderid].bold,
		       resp[:body][:statuscode],
		       resp[:body][:data][:exitcode],
		       resp[:body][:statusmsg])
		successpatch+=1
	end
end

if !errorpatch.empty?
	printf("EE:".bold.red+" Unpatched Hosts:\n")
	errorpatch.each do |error|
		printf("EE:".bold.red+"    %s\n",error.bold)
	end
end

printf("II: %s host(s) patched successfully.\n", successpatch)
#printrpcstats
