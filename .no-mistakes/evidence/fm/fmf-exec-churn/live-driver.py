import os, pathlib, shutil, subprocess, time, json, shlex
root=pathlib.Path.cwd(); evidence=pathlib.Path('/Users/jasonmatthew/.no-mistakes/evidence/01M4QZBQAEBS6KP11FKDPYAMA8'); tmp=root/'.test-disposable'/'live'
tmp.mkdir(); base=tmp/'base'; shutil.copytree(root/'bin',base/'bin')
for name in subprocess.check_output(['git','diff','--name-only','3067cd12','HEAD','--','bin'],text=True).splitlines():
    (base/name).write_bytes(subprocess.check_output(['git','show','3067cd12:'+name]))
env=os.environ.copy()
for k in list(env):
    if k.startswith('FM_') or k in ['TMUX','TASKS_AXI_FILE','TASKS_AXI_BACKEND']: env.pop(k,None)
env['TMPDIR']=str(root/'.test-disposable'); env['FM_PROCEVENT_CLAIM_ROOT']=str(tmp/'claims'); env['XDG_STATE_HOME']=str(tmp/'xdg')
programs='sleep ps sed tr awk uname id jq git gh stat perl cat dirname basename mkdir ln mktemp mv rm sh cut grep'.split()
runs=[]
try:
    for shell in [shutil.which('bash'),'/bin/bash']:
        for label,code in [('base',base),('head',root)]:
            tag=label+'-'+('stock' if shell=='/bin/bash' else 'path'); home=tmp/tag
            subprocess.run(['bash',str(root/'bin/fm-lab-home.sh'),'create',str(home)],check=True,env=env,stdout=subprocess.DEVNULL)
            log=evidence/(tag+'-starts.log'); log.write_text(''); shim=home/'shim'; shim.mkdir()
            for p in programs:
                real=shutil.which(p)
                if not real: continue
                f=shim/p; f.write_text('#!/bin/sh\nprintf "%s\\n" '+shlex.quote(p)+' >> '+shlex.quote(str(log))+'\nexec '+shlex.quote(real)+' "$@"\n'); f.chmod(0o700)
            f=shim/'bash'; f.write_text('#!/bin/sh\nexec '+shlex.quote(shell)+' \"$@\"\n'); f.chmod(0o700)
            e=env|{'FM_HOME':str(home),'PATH':str(shim)+':'+env['PATH']}
            output=open(evidence/(tag+'-monitor.log'),'w')
            proc=subprocess.Popen([shell,str(code/'bin/fm-watch-checkpoint.sh'),'--seconds','62'],env=e,stdout=output,stderr=subprocess.STDOUT)
            runs.append((tag,proc,output,log,home))
    time.sleep(20)
    for _,_,_,log,_ in runs: log.write_text('')
    time.sleep(35)
    summary={}
    for tag,proc,output,log,home in runs:
        lines=log.read_text().splitlines(); summary[tag]={'sample_seconds':35,'requested_starts':len(lines),'starts_per_second':len(lines)/35,'programs':{p:lines.count(p) for p in sorted(set(lines))},'beacon_exists':(home/'state/.last-watcher-beat').exists()}
        (evidence/(tag+'-window.log')).write_text('\n'.join(lines)+'\n')
    for tag,proc,output,log,home in runs:
        summary[tag]['checkpoint_exit']=proc.wait(timeout=20); output.close(); summary[tag]['lock_released']=not (home/'state/.watch.lock/pid').exists()
    for kind in ['stock','path']:
        assert summary['head-'+kind]['requested_starts'] < summary['base-'+kind]['requested_starts'],summary
    assert all(s['checkpoint_exit']==124 and s['lock_released'] and s['beacon_exists'] for s in summary.values()), summary
    (evidence/'idle-measurement.json').write_text(json.dumps(summary,indent=2)+'\n'); print(json.dumps(summary,indent=2)); print('PASS: real idle monitors reduced requested starts on both Bash versions, kept beacons, and released locks at timeout')
finally:
    for _,proc,output,_,_ in runs:
        if proc.poll() is None: proc.terminate(); proc.wait(timeout=10)
        output.close()
    shutil.rmtree(tmp)
