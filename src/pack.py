# -*- coding: utf-8 -*-
# pack.py - build the 1.1.0 delivery zip with UTF-8 entry names.
# PowerShell 5.1 Compress-Archive writes ANSI entry names, which show as
# mojibake in 7-Zip / unzip / macOS, so the package is built with Python.
import os
import zipfile
import datetime

root = r'C:\Users\mingjiu.wang\WorkBuddy\公司网络设备调试\ProxyClient_Packages'
d = os.path.join(root, 'exe_delivery')
out = os.path.join(root, '格一代理_Win_EXE_交付包.zip')

if os.path.exists(out):
    prevdir = os.path.join(root, '_prev')
    if not os.path.isdir(prevdir):
        os.makedirs(prevdir)
    stamp = datetime.datetime.now().strftime('%H%M%S')
    os.replace(out, os.path.join(prevdir, '格一代理_Win_EXE_交付包_prev_%s.zip' % stamp))

with zipfile.ZipFile(out, 'w', zipfile.ZIP_DEFLATED) as z:
    z.write(os.path.join(d, '格一代理.exe'), '格一代理.exe')
    z.write(os.path.join(d, 'payload', 'README.txt'), '交付说明.txt')
    z.write(os.path.join(d, '金丝雀验证记录.txt'), '金丝雀验证记录.txt')
    preview = os.path.join(d, '图标预览.png')
    if os.path.exists(preview):
        z.write(preview, '图标预览.png')

    # Ready-to-publish upgrade point (manifest already carries this exe's SHA256/SIZE)
    pub = os.path.join(d, 'publish')
    for f in sorted(os.listdir(pub)):
        z.write(os.path.join(pub, f), 'publish/' + f)

    # Canary drill scripts (audit trail)
    for f in ('canary.ps1', 'canary_upgrade.ps1'):
        p = os.path.join(d, f)
        if os.path.exists(p):
            z.write(p, '验证/' + f)

    src = os.path.join(d, 'src')
    for f in sorted(os.listdir(src)):
        z.write(os.path.join(src, f), '源码/' + f)
    pay = os.path.join(d, 'payload')
    for f in sorted(os.listdir(pay)):
        z.write(os.path.join(pay, f), '源码/payload/' + f)

with zipfile.ZipFile(out) as z:
    names = z.namelist()
    bad = [n for n in names if any(ord(c) > 127 for c in n) and not (z.getinfo(n).flag_bits & 0x800)]
print('ZIP=' + out)
print('SIZE=' + str(os.path.getsize(out)))
print('ENTRIES=' + str(len(names)))
print('PRIV_ENTRIES=' + str(len([n for n in names if 'priv' in n.lower()])))
print('NON_UTF8_NAMES=' + str(len(bad)))
for n in names[:8]:
    print('  ' + n)
