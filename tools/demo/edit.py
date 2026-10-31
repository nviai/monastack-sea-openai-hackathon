"""Add English narration, chapter headings and action highlights to a real demo."""
import argparse, datetime, json, subprocess, textwrap
from pathlib import Path
ROOT = Path(__file__).resolve().parents[2]
def run(args): subprocess.run(args,check=True,stdout=subprocess.DEVNULL)
def duration(path): return float(subprocess.check_output(['ffprobe','-v','error','-show_entries','format=duration','-of','default=nw=1:nk=1',str(path)],text=True))
def main():
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('recording',type=Path);args=parser.parse_args()
    folder=args.recording.resolve();raw=folder/'demo-raw.mp4'
    chapters=[json.loads(l) for l in (folder/'chapters.jsonl').read_text().splitlines()]
    zero=datetime.datetime.fromisoformat(chapters[0]['time'])
    starts=[(datetime.datetime.fromisoformat(c['time'])-zero).total_seconds() for c in chapters]
    length=duration(raw)
    narrations=[
      (0,.5,'Meet Monastack. Your AI office, with a specialist for every task.'),
      (3,1,'Organize your work into projects. Explore Meslingo, Vibe KOL, and Omit X, with clear cards for every project.'),
      (3,15,'Follow each task from to do, through work in progress, to done.'),
      (4,1,'Choose Atlas, the software engineer, and propose an onboarding review. The assignment remains pending for human approval.'),
      (5,.4,'Notifications keep requests and updates in one place.'),
      (6,.8,'Room chat keeps the conversation connected to your team. This is the live Dev and QA conversation.'),
    ]
    speech=folder/'narration';speech.mkdir(exist_ok=True)
    clips=[];captions=[]
    for i,(chapter,offset,text) in enumerate(narrations):
        start=starts[chapter]+offset
        text_file=speech/f'{i:02}.txt';text_file.write_text(text)
        audio=speech/f'{i:02}.aiff'
        run(['say','-v','Samantha','-r','172','-f',str(text_file),'-o',str(audio)])
        clip_length=duration(audio)
        if start+clip_length > (starts[chapter+1] if chapter+1<len(starts) else length)-.2:
            raise RuntimeError(f'Narration {i} exceeds chapter; shorten its script')
        clips.append((audio,start))
        caption=speech/f'{i:02}-caption.txt';caption.write_text(textwrap.fill(text,115))
        captions.append((caption,start,start+clip_length+.3))
    inputs=['ffmpeg','-hide_banner','-loglevel','warning','-y','-f','lavfi','-t',str(length),'-i','anullsrc=r=48000:cl=stereo']
    graph=[]
    for i,(audio,start) in enumerate(clips,1):
        inputs+=['-i',str(audio)]
        graph.append(f'[{i}:a]aformat=sample_rates=48000:channel_layouts=stereo,loudnorm=I=-18:TP=-2:LRA=7,adelay={int(start*1000)}|{int(start*1000)}[n{i}]')
    graph.append('[0:a]'+''.join(f'[n{i}]' for i in range(1,len(clips)+1))+f'amix=inputs={len(clips)+1}:duration=first:normalize=0[narration]')
    run(inputs+['-filter_complex',';'.join(graph),'-map','[narration]','-c:a','pcm_s16le','-ar','48000',str(folder/'narration.wav')])
    font=ROOT/'app/assets/fonts/inter-4.1/InterVariable.ttf'
    video=['scale=1480:-2','pad=1920:1080:(ow-iw)/2:60:color=0xf7f5ef']
    for i,chapter in enumerate(chapters[:-1]):
        path=speech/f'chapter-{i}.txt';path.write_text(chapter['chapter'])
        end=starts[i+1]
        video.append(f"drawtext=fontfile='{font}':textfile='{path}':fontcolor=0x253d38:fontsize=29:x=220:y=16:enable='between(t,{starts[i]},{end})'")
    # Rectangles follow the actual UI, expressed relative to the captured app.
    highlights=[(0,1,5,(.53,.28,.32,.48)),(1,2,5,(.82,.04,.17,.88)),
      (2,2,6,(.01,.28,.13,.10)),(3,2,10,(.15,.21,.70,.18)),
      (3,16,24,(.15,.46,.70,.42)),(4,3,9,(.31,.31,.38,.17)),
      (6,2,8,(.15,.18,.70,.67))]
    for chapter,a,b,(x,y,w,h) in highlights:
        video.append(f"drawbox=x={220+x*1480}:y={60+y*928}:w={w*1480}:h={h*928}:color=0xc89852@0.9:t=4:enable='between(t,{starts[chapter]+a},{min(starts[chapter]+b,starts[chapter+1])})'")
    for path,start,end in captions:
        video.append(f"drawbox=x=220:y=997:w=1480:h=68:color=0x253d38@0.95:t=fill:enable='between(t,{start},{end})'")
        video.append(f"drawtext=fontfile='{font}':textfile='{path}':fontcolor=white:fontsize=22:line_spacing=5:x=244:y=1007:enable='between(t,{start},{end})'")
    filters='[0:v]'+','.join(video)+'[v];[1:a]asplit[narr][side];[0:a][side]sidechaincompress=threshold=0.025:ratio=6:attack=10:release=250[bed];[bed][narr]amix=inputs=2:duration=first:normalize=0,alimiter=limit=0.95[a]'
    script=folder/'edit-filter.txt';script.write_text(filters)
    run(['ffmpeg','-hide_banner','-loglevel','warning','-y','-i',str(raw),'-i',str(folder/'narration.wav'),'-filter_complex_script',str(script),'-map','[v]','-map','[a]','-c:v','libx264','-preset','veryfast','-crf','20','-pix_fmt','yuv420p','-c:a','aac','-b:a','192k','-ar','48000','-movflags','+faststart',str(folder/'monastack-demo-narrated.mp4')])
    print(folder/'monastack-demo-narrated.mp4')
if __name__=='__main__': main()
