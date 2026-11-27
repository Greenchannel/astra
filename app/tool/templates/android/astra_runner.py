"""Minimal Chaquopy execution bridge used by the Android Astra app."""

import contextlib
import io
import json
import os
import sys
import time
import traceback

MAX_OUTPUT = 20000


def run_code(code, workspace, timeout_ms=30000):
    stdout = io.StringIO()
    stderr = io.StringIO()
    timed_out = False
    exit_code = 0
    old_cwd = os.getcwd()
    started = time.monotonic()
    deadline = started + max(1.0, float(timeout_ms) / 1000.0)

    def tracer(frame, event, arg):
        if event == "line" and time.monotonic() > deadline:
            raise TimeoutError("Astra Python execution timed out")
        return tracer

    try:
        os.makedirs(workspace, exist_ok=True)
        os.chdir(workspace)
        sys.settrace(tracer)
        with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
            try:
                compiled = compile(code, "<astra>", "exec")
                exec(compiled, {"__name__": "__main__"})
            except TimeoutError:
                timed_out = True
                exit_code = 1
                traceback.print_exc()
            except BaseException:
                exit_code = 1
                traceback.print_exc()
    except BaseException:
        exit_code = 1
        traceback.print_exc(file=stderr)
    finally:
        sys.settrace(None)
        try:
            os.chdir(old_cwd)
        except OSError:
            pass

    out = stdout.getvalue()
    err = stderr.getvalue()
    if len(out) > MAX_OUTPUT:
        out = out[:MAX_OUTPUT] + "\n…(output truncated)"
    if len(err) > MAX_OUTPUT:
        err = err[:MAX_OUTPUT] + "\n…(output truncated)"

    return json.dumps(
        {
            "stdout": out,
            "stderr": err,
            "exitCode": exit_code,
            "timedOut": timed_out,
        }
    )
