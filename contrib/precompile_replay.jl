import REPL
include(joinpath(Sys.STDLIB, "REPL", "test", "FakeTerminals.jl"))
import .FakeTerminals.FakeTerminal

const CTRL_C = '\x03'

# TODO: Have a utility to generate this from a real REPL session?
precompile_script = """
2+2
@time 1+1
?reinterpret
;ls
using Ra\t$CTRL_C
\\alpha\t$CTRL_C
\e[200~paste here ;)\e[201~"$CTRL_C
"""

function kill_timer(delay)
    # Give ourselves a generous timer here, just to prevent
    # this causing e.g. a CI hang when there's something unexpected in the output.
    # This is really messy and leaves the process in an undefined state.
    # the proper and correct way to do this in real code would be to destroy the
    # IO handles: `close(stdout_read); close(stdin_write)`
    test_task = current_task()
    function kill_test(t)
        # **DON'T COPY ME.**
        # The correct way to handle timeouts is to close the handle:
        # e.g. `close(stdout_read); close(stdin_write)`
        schedule(test_task, "hard kill repl test"; error=true)
        print(stderr, "WARNING: attempting hard kill of repl test after exceeding timeout\n")
    end
    return Timer(kill_test, delay)
end

# REPL tests
function fake_repl(@nospecialize(f); options::REPL.Options=REPL.Options(confirm_exit=false))
    # Use pipes so we can easily do blocking reads
    # In the future if we want we can add a test that the right object
    # gets displayed by intercepting the display
    input = Pipe()
    output = Pipe()
    err = Pipe()
    Base.link_pipe!(input, reader_supports_async=true, writer_supports_async=true)
    Base.link_pipe!(output, reader_supports_async=true, writer_supports_async=true)
    Base.link_pipe!(err, reader_supports_async=true, writer_supports_async=true)

    repl = REPL.LineEditREPL(FakeTerminal(input.out, output.in, err.in), true)
    repl.options = options

    hard_kill = kill_timer(900) # Your debugging session starts now. You have 15 minutes. Go.
    f(input.in, output.out, repl)
    t = @async begin
        close(input.in)
        close(output.in)
        close(err.in)
    end
    @assert read(err.out, String) == ""
    # print((read(output.out, String)))
    Base._wait(t)
    close(hard_kill)
    nothing
end

# Writing ^C to the repl will cause sigint, so let's not die on that
ccall(:jl_exit_on_sigint, Cvoid, (Cint,), 0)

fake_repl() do stdin_write, stdout_read, repl
    repl.specialdisplay = REPL.REPLDisplay(repl)
    repl.history_file = false

    repltask = @async begin
        REPL.run_repl(repl)
    end

    global inc = false
    global b = Condition()
    global c = Condition()
    let cmd = "\"Hello REPL\""
        write(stdin_write, "Main.inc || wait(Main.b); r = $cmd; notify(Main.c); r\r")
    end
    inc = true
    notify(b)
    wait(c)

    write(stdin_write, precompile_script)

    s = readavailable(stdout_read)

    # Close REPL ^D
    write(stdin_write, '\x04')
    Base._wait(repltask)

    nothing
end