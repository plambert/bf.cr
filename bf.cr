# brain**** interpreter in Crystal
# takes the program as an first argument
# compile with `crystal build bf.cr`
# run with `./bf [options] <path/to/file.b>`

def show_usage
  STDOUT.print <<-USAGE
    usage: bf [options] </path/to/file.b>

    options:
      --help, -h       This help text
      --memsize, -m    Size of the memory "tape" in bytes. Default: 30,000
      --maxsteps, -S   Set the limit to the number of steps to run before aborting. Set to 0 to disable. Default: 100,000,000
      --maxtime, -t    Set the limit to the number of seconds to run before aborting. Set to 0 to disable. Default: 60
      --optimize, -o   Enable optimizations. Default: off (--no-optimize)
      --output-delay   Set the number of milliseconds to delay after outputting a character. Default: 0
      --summary, -s    Show a performance summary at the end. Default: off (--no-summary)
      --progress, -p   Show progress info. Default: off (--no-progress)
      --verbose, -v    Show verbose output (it's ugly!)
    USAGE
end

memsize = 30_000
verbose = false
maxtime = 60.seconds
maxsteps = 100_000_000
show_summary = false
show_progress = false
output_delay : Time::Span? = nil
optimizations = false
jump_target = {} of Int32 => Int32
jump_cache_hits = 0

programfile : String? = nil

while opt = ARGV.shift?
  case opt
  when "--help", "-h"
    show_usage
    exit 0
  when "--memsize", "-m"
    memsize = ARGV.shift?.try(&.to_i) || raise ArgumentError.new "expected a parameter for #{opt}"
  when "--verbose", "-v"
    verbose = true
  when "--maxsteps", "-S"
    maxsteps = ARGV.shift?.try(&.to_i) || raise ArgumentError.new "expected a parameter for #{opt}"
  when "--maxtime", "-t"
    secs = ARGV.shift?.try(&.to_i) || raise ArgumentError.new "expected a parameter for #{opt}"
    maxtime = secs.seconds
  when "--output-delay"
    msecs = ARGV.shift?.try(&.to_i) || raise ArgumentError.new "expected a parameter for #{opt}"
    output_delay = msecs.milliseconds
  when "--no-output-delay"
    output_delay = nil
  when "--progress", "-p"
    show_progress = true
  when "--no-progress"
    show_progress = false
  when "--optimize", "-o"
    optimizations = true
  when "--no-optimize"
    optimizations = false
  when "--summary", "-s"
    show_summary = true
  when "--no-summary"
    show_summary = false
  when %r{^-}
    raise ArgumentError.new "#{opt}: unknown option"
  else
    raise ArgumentError.new "#{opt}: only one file can be run" if programfile
    programfile = opt
  end
end

raise ArgumentError.new "no program file given" unless programfile

memory = Bytes.new(memsize)
program = File.read programfile
if optimizations
  program = program.gsub(%r{[^\[\]\-\+,\.<>]+}, "")
end
op_count = Array(Int32).new(program.size, 1)
if optimizations
  idx = 0
  while idx < program.size
    case op = program[idx]
    when '+', '-', '>', '<'
      opc = 1
      while idx + opc < program.size && program[idx + opc] == op
        opc += 1
      end
      op_count[idx] = opc
    end
    idx += 1
  end
end
memptr = 0
prgptr = 0
step = 0
last_prgptr = memsize - 1
output = IO::Memory.new
starttime = Time.utc

def visualize(mem, ptr)
  STDERR.print "["
  8.times do |idx|
    STDERR.print " " if idx > 0
    STDERR.print "\e[31;1m" if idx == ptr
    STDERR.printf "%02x", mem[idx]
    STDERR.print "\e[0m" if idx == ptr
  end
  STDERR.print "]\n"
  # STDERR.printf "[[%s]]\n", mem[0..7].map{|v|"%02x" % v}.join(" ")
end

loop do
  break if prgptr >= program.size
  step += 1
  raise "too many steps" if maxsteps > 0 && step > maxsteps
  raise "timeout" if !maxtime.zero? && Time.utc - starttime > maxtime
  raise "did not move prgptr" if last_prgptr == prgptr
  last_prgptr = prgptr
  visualize memory, memptr if verbose
  STDERR.printf "%3d: %8d: %-5s ", step, prgptr, program[prgptr].inspect if verbose
  case program[prgptr]
  when '>'
    STDERR.printf "memptr %d", memptr if verbose
    memptr += op_count[prgptr]
    memptr = 0 if memptr >= memsize
    STDERR.printf " -> %d\n", memptr if verbose
    prgptr += op_count[prgptr]
  when '<'
    STDERR.printf "memptr %d", memptr if verbose
    memptr -= op_count[prgptr]
    memptr = memsize - 1 if memptr < 0
    STDERR.printf " -> %d\n", memptr if verbose
    prgptr += op_count[prgptr]
  when '+'
    STDERR.printf "inc %d: %d ", memptr, memory[memptr] if verbose
    op_count[prgptr].times do
      if memory[memptr] == 255
        memory[memptr] = 0
      else
        memory[memptr] += 1
      end
    end
    STDERR.printf " -> %d\n", memory[memptr] if verbose
    prgptr += op_count[prgptr]
  when '-'
    STDERR.printf "dec %d: %d ", memptr, memory[memptr] if verbose
    op_count[prgptr].times do
      if memory[memptr] == 0
        memory[memptr] = 255
      else
        memory[memptr] -= 1
      end
    end
    STDERR.printf " -> %d\n", memory[memptr] if verbose
    prgptr += op_count[prgptr]
  when '.'
    char = memory[memptr].unsafe_chr
    if output_delay
      STDOUT.print char
      sleep output_delay
    else
      output << char
    end
    STDERR.printf "write %d: %d (%s)\n", memptr, memory[memptr], char.inspect if verbose
    prgptr += 1
  when ','
    buffer = Bytes.new(1)
    count = STDIN.read(buffer)
    memory[memptr] = buffer[0]
    STDERR.printf "read %d (%s)\n", buffer[0], buffer[0].unsafe_chr.inspect if verbose
    prgptr += 1
  when '['
    STDERR.printf "%d = %d", memptr, memory[memptr] if verbose
    if memory[memptr] == 0
      STDERR.print " begin\n" if verbose
      if jump_target[prgptr]?
        prgptr = jump_target[prgptr]
        jump_cache_hits += 1
      else
        depth = 1
        jumpptr : Int32 = prgptr
        while depth > 0
          jumpptr += 1
          if program[jumpptr] == ']'
            depth -= 1
          elsif program[jumpptr] == '['
            depth += 1
          end
          STDERR.printf "     %8d: %-8s depth %8d\n", jumpptr, program[jumpptr].inspect, depth if verbose
        end
        jump_target[prgptr] = jumpptr
        prgptr = jumpptr
      end
    else
      STDERR.print " (ignore)\n" if verbose
    end
    prgptr += 1
  when ']'
    STDERR.printf "%d = %d", memptr, memory[memptr] if verbose
    if memory[memptr] != 0
      STDERR.print " begin\n" if verbose
      if jump_target[prgptr]?
        prgptr = jump_target[prgptr]
        jump_cache_hits += 1
      else
        depth = 1
        jumpptr = prgptr
        while depth > 0
          jumpptr -= 1
          if program[jumpptr] == ']'
            depth += 1
          elsif program[jumpptr] == '['
            depth -= 1
          end
          STDERR.printf "     %8d: %-8s [%8d]\n", jumpptr, program[jumpptr].inspect, depth if verbose
        end
        jump_target[prgptr] = jumpptr
        prgptr = jumpptr
      end
    else
      STDERR.print " (ignore)\n" if verbose
    end
    prgptr += 1
  else
    STDERR.printf "comment %s\n", program[prgptr].inspect if verbose
    prgptr += 1
  end
end

puts output.to_s unless output_delay

if show_summary
  elapsed = Time.utc - starttime
  STDERR.printf "%d steps executed in %.4f seconds, %.2f (%s) steps/second with %d jump cache hits\n",
    step, elapsed.total_seconds, step / elapsed.total_seconds, (step / elapsed.total_seconds).humanize, jump_cache_hits
end
