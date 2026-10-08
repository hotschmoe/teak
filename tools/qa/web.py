#!/usr/bin/env python3
# Web half of the visual QA sweep: drives each example's `zig build web` dist/ in headless
# Chromium (tools/qa/web.mjs) at 1x and 2x. usage: web.py [example|all] [out-dir]
import json,subprocess,sys,os
R=os.path.abspath(os.path.join(os.path.dirname(__file__),'..','..'))
OUT=sys.argv[2] if len(sys.argv)>2 else '/tmp/qa'
env=dict(os.environ,CHROME_PATH='/usr/bin/chromium',WEBSHOT_ANGLE='vulkan')
def C(x,y): return {"click":[x,y]}
def T(t): return {"type":t}
def K(k,shift=False): return {"key":k,"shift":shift} if shift else {"key":k}
S=[
 ("chrome","initial",1280,800,"",[]),
 ("chrome","modern",1280,800,"",[K("m"),{"move":[600,500],"wait":1200}]),
 ("counter_greeter","initial",900,500,"",[]),
 ("counter_greeter","counted_named",900,500,"",[C(70,134),C(70,134),C(70,134),C(284,98),T("Teak"),{"move":[600,400]}]),
 ("counter_greeter","help_modal",900,500,"",[C(38,25)]),
 ("counter_greeter","light_mode",900,500,"",[C(126,25),{"move":[600,400]}]),
 ("todo","initial",720,600,"",[]),
 ("todo","three_items",720,600,"",[C(80,66),T("Buy milk"),K("Enter"),T("Write the golden tests"),K("Enter"),T("Ship it"),K("Enter"),C(33,171),{"move":[400,400]}]),
 ("tree","initial",720,600,"",[]),
 ("viewport","initial",900,520,"",[]),
 ("viewport","zoomed_panned",900,520,"",[{"move":[290,240]},{"wheel":[290,240,-240]},{"drag":[[300,250],[380,300]]}]),
 ("effects","initial",1000,640,"",[]),
 ("fonts","initial",1000,520,"",[]),
 ("scene3d","initial",1280,800,"",[]),
 ("kerf_viewer","section",1280,800,"",[]),
 ("kerf_viewer","three_d",1280,800,"?tab=3d&select=stem",[]),
 ("gallery","controls",1280,800,"",[]),
 ("gallery","controls_dark",1280,800,"",[C(88,720),{"move":[900,700]}]),
 ("gallery","controls_light",1280,800,"",[C(88,752),{"move":[900,700]}]),
 ("gallery","data",1280,800,"",[C(88,142)]),
 ("gallery","inputs",1280,800,"",[C(88,110)]),
 ("gallery","overlays",1280,800,"",[C(88,174)]),
 ("gallery","overlays_dialog",1280,800,"",[C(88,174),C(790,263)]),
 ("gallery","layout",1280,800,"",[C(88,206)]),
 ("gallery","scene",1280,800,"",[C(88,238)]),
 ("notes","initial",1280,800,"",[]),
 ("tables","initial",1100,700,"",[]),
]
only=sys.argv[1] if len(sys.argv)>1 and sys.argv[1]!='all' else None
only_state=os.environ.get('QA_STATE')
scales=[int(x) for x in os.environ.get('QA_SCALES','1,2').split(',')]
os.makedirs(OUT+'/web',exist_ok=True)
for ex,st,w,h,q,acts in S:
    if only and ex!=only: continue
    if only_state and st!=only_state: continue
    dist=f'{R}/examples/{ex}/dist'
    if not os.path.isdir(dist): print('skip',ex); continue
    for sc in scales:
        out=f'{OUT}/web/{ex}-{st}@{sc}x.png'
        cmd=['node',f'{R}/tools/qa/web.mjs',dist,out,'--width',str(w),'--height',str(h),'--dsf',str(sc),'--wait-ms','5000','--query',q,'--actions',json.dumps(acts)]
        r=subprocess.run(cmd,capture_output=True,text=True,env=env)
        ok='OK' if 'WEBSHOT OK' in r.stdout else 'FAIL '+r.stdout[-200:]+r.stderr[-200:]
        print(ex,st,sc,ok,flush=True)
