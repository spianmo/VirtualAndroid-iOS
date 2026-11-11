"""lldb stand-in for StikDebug's universal.js, for testing the engine's iOS 26
JIT region protocol from a Mac over USB.

    xcrun lldb -b -o "command script import tools/jit/jit_host.py" \
                  -o "vajit <device-id> <pid> [log]"

Handles, like StikDebug 3.2 universal.js:
  brk #0x69            -> refuses it like universal.js: x0 = 0xcccccccc690000e0
  brk #0xf00d, x16=1   -> "prepare region": write one byte (0x69) at the start of
                          every 16 KiB page of [x0, x0+x1) through debugserver,
                          x0 = address
  brk #0xf00d, x16=0   -> detach
Any other stop is continued (signals passed on).
"""
import time

import lldb

PAGE = 16384


def _reg(frame, name):
    return frame.FindRegister(name).GetValueAsUnsigned()


def _set_reg(frame, name, value):
    err = lldb.SBError()
    frame.FindRegister(name).SetValueFromCString("0x%x" % value, err)
    if not err.Success():
        raise RuntimeError("set %s: %s" % (name, err.GetCString()))


def vajit(debugger, command, result, internal_dict):
    args = command.split()
    device, pid = args[0], int(args[1])
    logf = open(args[2], "a") if len(args) > 2 else None

    def log(msg):
        line = "%s %s" % (time.strftime("%H:%M:%S"), msg)
        print(line)
        if logf:
            logf.write(line + "\n")
            logf.flush()

    debugger.SetAsync(False)
    ci = debugger.GetCommandInterpreter()
    res = lldb.SBCommandReturnObject()
    ci.HandleCommand("device select %s" % device, res)
    log("select: %s %s" % (res.GetOutput().strip(), res.GetError().strip()))
    res = lldb.SBCommandReturnObject()
    t0 = time.time()
    ci.HandleCommand("device process attach -p %d" % pid, res)
    log("attach (%.1f s): %s %s" % (time.time() - t0, res.GetOutput().strip()[:200], res.GetError().strip()))
    target = debugger.GetSelectedTarget()
    process = target.GetProcess()
    if not process.IsValid():
        log("no process")
        return
    for sig in ("SIGUSR1", "SIGUSR2", "SIGPIPE", "SIGALRM", "SIGCHLD", "SIGIO", "SIGURG", "SIGWINCH"):
        r = lldb.SBCommandReturnObject()
        ci.HandleCommand("process handle -p true -s false -n false %s" % sig, r)

    stops = 0
    while True:
        err = process.Continue()
        state = process.GetState()
        if state in (lldb.eStateExited, lldb.eStateDetached, lldb.eStateCrashed) or not process.IsValid():
            log("process state %s, exit %s" % (lldb.SBDebugger.StateAsCString(state), process.GetExitStatus()))
            break
        stops += 1
        thread = None
        for t in process:
            if t.GetStopReason() not in (lldb.eStopReasonNone, lldb.eStopReasonInvalid):
                thread = t
                break
        if thread is None:
            log("stop %d without a reason, continuing" % stops)
            continue
        process.SetSelectedThread(thread)
        frame = thread.GetFrameAtIndex(0)
        pc = frame.GetPC()
        e = lldb.SBError()
        raw = process.ReadMemory(pc, 4, e)
        insn = int.from_bytes(raw, "little") if e.Success() else 0
        if (insn & 0xFFE0001F) != 0xD4200000:
            desc = thread.GetStopDescription(200)
            log("stop %d at 0x%x: %s (not a brk), continuing" % (stops, pc, desc))
            continue
        imm = (insn >> 5) & 0xFFFF
        x0, x1, x16 = _reg(frame, "x0"), _reg(frame, "x1"), _reg(frame, "x16")
        frame.SetPC(pc + 4)
        if imm == 0x69:
            log("brk #0x69 x0=0x%x x1=0x%x: refusing like universal.js" % (x0, x1))
            _set_reg(frame, "x0", 0xCCCCCCCC690000E0)
        elif imm == 0xF00D and x16 == 1:
            n = (x1 + PAGE - 1) // PAGE if x1 else 0
            log("prepare region 0x%x + %d MB (%d pages)" % (x0, x1 >> 20, n))
            t1 = time.time()
            werr = lldb.SBError()
            for i in range(n):
                process.WriteMemory(x0 + i * PAGE, b"\x69", werr)
                if not werr.Success():
                    log("write at 0x%x failed: %s" % (x0 + i * PAGE, werr.GetCString()))
                    break
                if i and i % 4096 == 0:
                    log("  %d/%d pages, %.1f s" % (i, n, time.time() - t1))
            log("prepared %d pages in %.1f s" % (n, time.time() - t1))
            _set_reg(frame, "x0", x0)
        elif imm == 0xF00D and x16 == 0:
            log("detach requested")
            process.Detach()
            log("detached after %d stops" % stops)
            break
        else:
            log("brk #0x%x x16=%d not handled, skipped" % (imm, x16))
    if logf:
        logf.close()


def __lldb_init_module(debugger, internal_dict):
    debugger.HandleCommand("command script add -f jit_host.vajit vajit")
