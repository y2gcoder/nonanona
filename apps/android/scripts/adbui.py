"""adb + UI Automator 도우미(Python 표준 라이브러리만). native-batch-import 실험의 도우미를 줄여 옮겼다."""

import os
import re
import subprocess
import time
import xml.etree.ElementTree as ET

ADB = os.path.join(os.environ.get("ANDROID_HOME", os.path.expanduser("~/Library/Android/sdk")), "platform-tools", "adb")


def adb(*args, check=True, binary=False):
    r = subprocess.run([ADB, *args], capture_output=True, check=check)
    return r.stdout if binary else r.stdout.decode("utf-8", "replace")


def sh(cmd, check=True):
    return adb("shell", cmd, check=check)


class Node:
    def __init__(self, e):
        self.text = e.get("text", "")
        self.id = e.get("resource-id", "")
        self.desc = e.get("content-desc", "")
        self.enabled = e.get("enabled") == "true"
        self.checked = e.get("checked") == "true"
        x1, y1, x2, y2 = map(int, re.findall(r"\d+", e.get("bounds", "[0,0][0,0]")))
        self.bounds = (x1, y1, x2, y2)
        self.center = ((x1 + x2) // 2, (y1 + y2) // 2)

    def __repr__(self):
        return f"<id={self.id!r} text={self.text[:40]!r} desc={self.desc[:40]!r} {self.bounds}>"


def dump():
    for _ in range(6):
        out = sh("uiautomator dump /sdcard/ui.xml >/dev/null 2>&1; cat /sdcard/ui.xml", check=False)
        if out.startswith("<?xml"):
            return [Node(e) for e in ET.fromstring(out).iter("node")]
        time.sleep(0.5)
    raise RuntimeError("uiautomator dump failed")


def find(nodes=None, *, id=None, text=None, contains=None, desc=None):
    nodes = dump() if nodes is None else nodes
    for n in nodes:
        if id and not (n.id == id or n.id.endswith("/" + id)):
            continue
        if text is not None and n.text != text:
            continue
        if contains is not None and contains not in n.text:
            continue
        if desc is not None and n.desc != desc:
            continue
        return n
    return None


def wait(timeout=30, **query):
    deadline = time.time() + timeout
    while time.time() < deadline:
        n = find(**query)
        if n:
            return n
        time.sleep(0.5)
    raise TimeoutError(f"not found: {query}")


def gone(timeout=15, **query):
    deadline = time.time() + timeout
    while time.time() < deadline:
        if not find(**query):
            return
        time.sleep(0.5)
    raise TimeoutError(f"still visible: {query}")


def tap(node):
    sh(f"input tap {node.center[0]} {node.center[1]}")
    time.sleep(0.5)


def long_press(node):
    x, y = node.center
    sh(f"input swipe {x} {y} {x} {y} 900")
    time.sleep(0.6)


def back():
    sh("input keyevent KEYCODE_BACK")
    time.sleep(0.8)


def screenshot(path):
    with open(path, "wb") as f:
        f.write(adb("exec-out", "screencap", "-p", binary=True))


def scroll_to(timeout=30, **query):
    """목록을 아래로, 그다음 위로 넘기며 찾는다."""
    deadline = time.time() + timeout
    for swipe in ["540 1700 540 900"] * 6 + ["540 900 540 1700"] * 12:
        n = find(**query)
        if n and 150 < n.bounds[1] and n.bounds[3] < 2250:
            return n
        if time.time() > deadline:
            break
        sh(f"input swipe {swipe} 300")
        time.sleep(0.6)
    raise TimeoutError(f"not found while scrolling: {query}")


def texts_within(id):
    """Compose의 testTag 노드 안쪽에 그려진 글자들(상태 라벨처럼 글자가 자식 노드에 있는 경우)."""
    nodes = dump()
    box = find(nodes, id=id)
    if not box:
        return []
    x1, y1, x2, y2 = box.bounds
    return [n.text for n in nodes if n.text and x1 <= n.bounds[0] and n.bounds[2] <= x2 and y1 <= n.bounds[1] and n.bounds[3] <= y2]
