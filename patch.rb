#!/usr/bin/ruby
#
# This is a little smarter than a shell script.
#
#

require 'mcollective'
include MCollective::RPC
require 'pp'
require 'logger'

options = rpcoptions do |parser, options|
	parser.define_head "RedHat/Centos System Updater"
	parser.banner = "Usage: patch.rb [options] [filters]"

	parser.on('--bw', '--plain', 'Do not use colors') do |v|
		options[:bw] = v
	end
	parser.on('--all', '--all-hosts', 'Allow patching of all discovered hosts (no filters)') do |v|
		options[:allhosts] = v
	end
	parser.on('--rhncheck', '--rhncheck', 'Only run rhn_check') do |v|
		options[:rhncheck] = v
	end
	parser.on('--check', '--checkonly', 'Only check for updates') do |v|
		options[:checkonly] = v
	end
	parser.on('-l', '--logfile FILE', 'Log file to write (defaults to patch-YYMMDD-HHMM.log)') do |f|
		options[:logfile] = f
	end
end

if options.include?(:logfile)
	logfile=options[:logfile]
else
	logfile=("patch-%s.log" % Time.new.strftime("%y%m%d-%H%M"))
end

log = Logger.new(logfile)
outlog = Logger.new(STDOUT)

if options.include?(:verbose)
	log.level = Logger::DEBUG
	outlog.level = Logger::DEBUG
else
	log.level = Logger::INFO
	outlog.level = Logger::INFO
end

log.info("Logfile: "+logfile)
outlog.info("Logfile: "+logfile)

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

if options.include?(:checkonly) and options.include?(:rhncheck)
	outlog.fatal("Specify only one of check and rhncheck".bold.red)
	log.fatal("Specify only one of check and rhncheck")
	abort()
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
		outlog.fatal("You must provide a host filter!".bold.red)
		log.fatal("You must provide a host filter!")
		abort()
	end
end

# The list of systems flagged for a reboot (kernel update):
rebootlist=[]
errorlist=[]

# Status output
log.info("Finding matching hosts...")
outlog.info("Finding matching hosts...")

# Run a manual discovery so that we can keep the results
hostlist=yumrpc.discover

if hostlist.empty?
	log.fatal("No hosts found!")
	outlog.fatal("No hosts found!".bold.red)
	abort()
elsif hostlist.count > 30
	log.warn("Found more than 30 hosts (#{hostlist.count} total).")
	outlog.warn("Found more than 30 hosts (#{hostlist.count} total). Continue? (y/n)".bold.brown)
	input = gets.strip
	if input != "y" and input != "Y"
		log.fatal("Aborting at user request.")
		outlog.fatal("Aborting at user request.".bold.red)
		abort()
	end
else
	log.info("Found #{hostlist.count} host(s).")
	outlog.info("Found #{hostlist.count} host(s).")
end

hostcount=0

if !options.include?(:rhncheck)
	# Run check-update on everything in hostlist:
	yumrpc.custom_request("check-update",{},hostlist,yumrpc.filter) do |resp|
		# If yum exited with an error, remove the host from the list.
		if resp[:body][:statuscode] != 0
			log.error("#{resp[:senderid]}: ERROR: #{resp[:body][:statusmsg]}")
			outlog.error("#{resp[:senderid.bold.red]}: ERROR: #{resp[:body][:statusmsg]}")
			errorlist.push(resp[:senderid])
			hostlist.delete(resp[:senderid])
		else
			# If there are no packages to update, remove the host from the list
			if resp[:body][:data][:outdated_packages].empty?
				log.info("#{resp[:senderid]}: Up to date")
				outlog.info("#{resp[:senderid].bold.green}: Up to date")
				hostlist.delete(resp[:senderid])
			else
				log.info("#{resp[:senderid]}: ")
				outlog.info("#{resp[:senderid].bold}: ")
				resp[:body][:data][:outdated_packages].each do |package|
					if package[:package].include? "kernel"
						if !rebootlist.include?(resp[:senderid])
							rebootlist.push(resp[:senderid])
						end
					end
					log.info("    #{package[:package]}")
					outlog.info("    #{package[:package]}")
				end
				hostcount += 1
			end
		end
	end

	# Notify user of hosts that may need a reboot
	if !rebootlist.empty?
		outlog.warn("Reboot list:")
		log.warn("Reboot list:")
		rebootlist.each do |reboot|
			log.warn("    #{reboot}")
			outlog.warn("    #{reboot}")
		end
	end

	# List systems that had errors on check-update
	if !errorlist.empty?
		outlog.error("Errored Hosts:".bold.red)
		log.error("Errored Hosts:")
		errorlist.each do |error|
			outlog.error("    #{error}".bold.red)
			log.error("    #{error}".bold.red)
		end
	end

	if hostcount == 0
		outlog.fatal("No hosts need updates. Aborting.".bold.red)
		log.fatal("No hosts need updates. Aborting.")
		abort()
	else
		outlog.info("#{hostcount} host(s) need to be updated.")
		log.info("#{hostcount} host(s) need to be updated.")
	end

	# Exit if check-update is all that was requested
	if options.include?(:checkonly)
		outlog.info("Check-update complete. Exiting.")
		log.info("Check-update complete. Exiting.")
		abort()
	end
	printf "Do you want to patch these systems? (y/n only): ".bold
	input = gets.strip
	if input != "y" and input != "Y"
		outlog.fatal("Aborting at user request.".bold.red)
		log.fatal("Aborting at user request.")
		abort()
	end

	errorpatch=[]
	successpatch=0

	# Do the patching by calling the 'update' RPC.
	# Intentionally NOT rerunning discovery here. Using the existing response list,
	# after removing hosts with errors or 0 updates.

	yumrpc.custom_request("update",{},hostlist,yumrpc.filter) do |resp|
		# Check for errors in status or yum exit code
		if resp[:body][:statuscode] != 0 or resp[:body][:data][:exitcode] != 0
			outlog.error("#{resp[:senderid].bold.red}: #{resp[:body][:statuscode]} (exit #{resp[:body][:data][:exitcode]}), msg #{resp[:body][:statusmsg]}")
			log.error("EE: #{resp[:senderid]}: #{resp[:body][:statuscode]} (exit #{resp[:body][:data][:exitcode]}), msg #{resp[:body][:statusmsg]}")
			# This doesn't print much most of the time, but when it does it is error messages
			resp[:body][:data][:output].each do |line|
				outlog.error("    #{line}".bold.red, line)
				log.error("    #{line}".bold.red, line)
			end
			errorpatch.push(resp[:senderid])

			# Delete from the hostlist so that rhn_check is not run
			hostlist.delete(resp[:senderid])
		else
			outlog.info("#{resp[:senderid].bold}: #{resp[:body][:statuscode]} (exit #{resp[:body][:data][:exitcode]}), msg #{resp[:body][:statusmsg]}")
			log.info("#{resp[:senderid]}: #{resp[:body][:statuscode]} (exit #{resp[:body][:data][:exitcode]}), msg #{resp[:body][:statusmsg]}")
			successpatch+=1
		end
	end

	if !errorpatch.empty?
		outlog.error("Unpatched Hosts:".bold.red)
		log.error("Unpatched Hosts:")
		errorpatch.each do |error|
			outlog.error("    #{error.bold.red}")
			log.error("    #{error}")
		end
	end

	outlog.info("#{successpatch} host(s) patched successfully.")
	log.info("#{successpatch} host(s) patched successfully.")

	# from rhncheck-only
else
	# There is no host list output above so list them now
	hostlist.each do |host|
		outlog.info("#{host}")
		log.info("#{host}")
	end
end
printf "Do you want to run rhn_check on these systems? (y/n only): "
input = gets.strip
if input != "y" and input != "Y"
	outlog.fatal("Aborting at user request.".bold.red)
	log.fatal("Aborting at user request.")
	abort()
end

errorrhn=[]
successrhn=0

shellrpc = rpcclient("shellout", :options => options)
shellrpc.filter = yumrpc.filter
shellrpc.custom_request("cmd",{:cmd => "/usr/sbin/rhn_check"},hostlist,shellrpc.filter) do |resp|
	# Check for errors in status
	if resp[:body][:statuscode] != 0
		outlog.error("#{resp[:senderid].bold.red}: #{resp[:body][:statuscode]}, msg #{resp[:body][:statusmsg]}")
		log.error("#{resp[:senderid]}: #{resp[:body][:statuscode]}, msg #{resp[:body][:statusmsg]}")
		# This doesn't print much most of the time, but when it does it is error messages
		if !resp[:body][:data][:out].empty?
			resp[:body][:data][:out].each do |line|
				outlog.error("    #{line.bold.red}")
				log.error("    #{line}")
			end
		end
		errorrhn.push(resp[:senderid])
	else
		outlog.info("#{resp[:senderid].bold}: #{resp[:body][:statuscode]}, msg #{resp[:body][:statusmsg]}")
		log.info("#{resp[:senderid]}: #{resp[:body][:statuscode]}, msg #{resp[:body][:statusmsg]}")
		successrhn+=1
	end
end

if !errorrhn.empty?
	outlog.error("RHN_Check Errors:".bold.red)
	log.error("RHN_Check Errors:")
	errorrhn.each do |error|
		outlog.error("    #{error.bold.red}")
		log.error("    #{error}")
	end
end
outlog.info("#{successrhn} host(s) checked in successfully.")
log.info("#{successrhn} host(s) checked in successfully.")

