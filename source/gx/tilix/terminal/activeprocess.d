module gx.tilix.terminal.activeprocess;

import core.sys.posix.unistd;
import core.thread;

import std.algorithm;
import std.array;
import std.conv;
import std.experimental.logger;
import std.stdio;
import std.string;
import std.file;
import std.path;

/**
* A stripped-down (plus extended) version of psutil's Process class.
*/
class Process {

    pid_t pid;
    string[] processStat;
    static Process[pid_t] processMap;
    static Process[][pid_t] sessionMap;

    this(pid_t p)
    {
        pid = p;
        processStat = parseStatFile();
    }

    @property string name() {
        return processStat[0];
    }

    @property pid_t ppid() {
        return to!pid_t(processStat[2]);
    }

    string[] parseStatFile() {
        try {
            string data = to!string(cast(char[])read(format("/proc/%d/stat", pid)));
            long rpar = data.lastIndexOf(")");
            string name = data[data.indexOf("(") + 1..rpar];
            string[] other  = data[rpar + 2..data.length].split;
            return name ~ other;
        } catch (FileException fe) {
            warning(fe);
            }
        return [];
    }

    /**
    * Foreground process has a controlling terminal and
    * process group id == terminal process group id.
    */
    bool isForeground() {
        if (!Process.pidExists(pid)) {
            return false;
        }
        string[] tempStat = parseStatFile();
        long pgrp = to!long(tempStat[3]);
        long tty = to!long(tempStat[5]);
        long tpgid = to!long(tempStat[6]);
        return tty > 0 && pgrp == tpgid;
    }

    long createTime() {
        return to!long(processStat[20]);
    }

    bool hasTTY() {
        return to!long(processStat[5]) > 0;
    }

    /**
    * Shell PID == sessionID
    */
    pid_t sessionID() {
        return to!pid_t(processStat[4]);
    }

    /**
    * Returns all foreground child process of this Process.
    */
    Process[] fChildren() {
        Process[] ret = [];
        foreach (p; Process.sessionMap.get(sessionID(), [])) {
            if (p.ppid == pid && createTime() <= p.createTime()) {
                ret ~= p;
            }
        }
        return ret;
    }

    /**
    * Get all running PIDs of system.
    */
    static pid_t[] pids() {
        return std.file.dirEntries("/proc", SpanMode.shallow)
            .filter!(a => std.path.baseName(a.name).isNumeric)
            .map!(a => to!pid_t(std.path.baseName(a.name)))
            .array;
    }

    static bool pidExists(pid_t p) {
            return exists(format("/proc/%d", p));
    }

    /**
    * Create `Process` object of all PIDs and store them on
    * `Process.processMap` then store foreground processes
    * on `Process.sessionMap` using session id as their key.
    */
    static void updateMap() {

        Process add(pid_t p) {
            auto proc = new Process(p);
            Process.processMap[p] = proc;
            return proc;
        }

        void remove(pid_t p) {
            Process.processMap.remove(p);
        }

        auto pids = Process.pids().sort;
        auto pmapKeys = Process.processMap.keys.sort;
        auto gonePids = setDifference(pmapKeys, pids);

        foreach(p; gonePids) {
            remove(p);
        }

        Process.processMap.rehash();
        Process proc;
        Process.sessionMap.clear;

        foreach(p; pids) {
            if ((p in Process.processMap) !is null) {
                proc = Process.processMap[p]; // Cached process.
            } else if (Process.pidExists(p)) {
                proc = add(p); // New Process.
            }
            // Taking advantages of short-circuit operator `&&` using `proc.hasTTY()`
            // to reduce calling on `proc.isForeground()`.
            if (proc !is null && proc.hasTTY() && proc.isForeground()) {
                Process.sessionMap[proc.sessionID] ~= proc;
            }
        }
    }
}


/**
 * Get active process list of all terminals.
 * `Process.sessionMap` contains all foreground of all
 * open terminals using session id as their key. We are
 * iterating through all session id (shell PID) and trying to find
 * their active process and finally returning all active process.
 * Returning all active process is very efficient when there are too
 * many open terminals.
 */
Process[pid_t] getActiveProcessList() {
    //  Update `Process.sessionMap` and `Process.processMap`.
    Process.updateMap();
    Process[pid_t] ret;
    foreach(pid; Process.sessionMap.keys) {
        auto shellChild = Process.sessionMap[pid];
        auto shellChildCount = shellChild.length;
         // The shell process has only one foreground
         // process, so, it is an active process.
        if (shellChildCount == 1) {
            auto proc = shellChild[0];
            ret[proc.sessionID()] = proc;
        } else {
            // If we are lucky, last item is the active process :D
            foreach_reverse(proc; shellChild) {
                // If a foreground process has no foreground
                // child process then it is an active process.
                if(proc.fChildren().length == 0)
                    ret[proc.sessionID()] = proc;
                    break;
            }
        }
    }
    return ret;
}
