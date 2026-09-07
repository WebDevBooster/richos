#!/usr/bin/env python3
"""Unprivileged JSON client for the installed managed-workspace Unix broker."""
import argparse
import ctypes
import json
import os
import socket
import struct
import sys

DEFAULT_SOCKET = "/var/run/richos-workspaces/broker.sock"
MAX_REQUEST = 65536
MAX_RESPONSE = 1048576


class ClientError(RuntimeError):
    pass


def _server_uid(connection):
    if sys.platform == "darwin":
        libc = ctypes.CDLL(None, use_errno=True)
        getpeereid = libc.getpeereid
        getpeereid.argtypes = [ctypes.c_int, ctypes.POINTER(ctypes.c_uint), ctypes.POINTER(ctypes.c_uint)]
        getpeereid.restype = ctypes.c_int
        uid, gid = ctypes.c_uint(), ctypes.c_uint()
        if getpeereid(connection.fileno(), ctypes.byref(uid), ctypes.byref(gid)):
            raise ClientError("broker peer identity unavailable")
        return uid.value
    if sys.platform.startswith("linux"):
        return struct.unpack("3i", connection.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED, 12))[1]
    raise ClientError("unsupported kernel peer authentication")


def call(request, *, socket_path=DEFAULT_SOCKET, timeout=330):
    """Return one broker record. Root peer authentication is mandatory."""
    encoded = json.dumps(request, separators=(",", ":")).encode() + b"\n"
    if len(encoded) > MAX_REQUEST:
        raise ClientError("request exceeds size limit")
    try:
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
            connection.settimeout(timeout)
            connection.connect(os.fspath(socket_path))
            if _server_uid(connection) != 0:
                raise ClientError("broker peer is not root")
            connection.sendall(encoded)
            response = bytearray()
            while b"\n" not in response:
                chunk = connection.recv(min(65536, MAX_RESPONSE + 1 - len(response)))
                if not chunk:
                    raise ClientError("incomplete broker response")
                response.extend(chunk)
                if len(response) > MAX_RESPONSE:
                    raise ClientError("broker response exceeds size limit")
            line, remainder = bytes(response).split(b"\n", 1)
            if remainder.strip():
                raise ClientError("unexpected extra broker response")
            value = json.loads(line)
    except (OSError, ValueError) as exc:
        raise ClientError(str(exc)) from exc
    if not isinstance(value, dict) or value.get("ok") is not True or not isinstance(value.get("result"), dict):
        raise ClientError(str(value.get("error", "invalid broker response")) if isinstance(value, dict) else "invalid broker response")
    return value["result"]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--socket", default=DEFAULT_SOCKET)
    parser.add_argument("operation", nargs="?", choices=("health", "status"),
                        help="read approved-owner service health or durable workspace status")
    args = parser.parse_args()
    raw = (json.dumps({"operation": args.operation}).encode() if args.operation
           else sys.stdin.buffer.read(MAX_REQUEST + 1))
    try:
        if len(raw) > MAX_REQUEST:
            raise ClientError("request exceeds size limit")
        result = call(json.loads(raw), socket_path=args.socket)
        print(json.dumps(result, sort_keys=True))
        return 0
    except (ClientError, ValueError) as exc:
        print(str(exc), file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
