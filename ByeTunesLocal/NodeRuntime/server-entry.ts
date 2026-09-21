import http, { IncomingMessage, ServerResponse } from "node:http";
import { randomUUID } from "node:crypto";
import { mkdir, readFile, rm, writeFile } from "node:fs/promises";
import { join } from "node:path";
import {
  detectPlatform, detectUrlType, getPlaylistInfo, getAlbumInfo, getArtistTopTracks, type TrackInfo,
} from "./src/lib/spotify";
import {
  resolveTrack, resolvePlaylist, resolveAlbum, resolveArtist, getSpotifyFromUrl,
  type SpotifyFromUrlResponse, type SpotifyFromUrlTrack,
} from "./src/lib/resolve-track";
import { prepareTrackAssets } from "./src/lib/track-prep";
import { isCompilationAlbum } from "./src/lib/audio-metadata";
import { setExplicitTag } from "./src/lib/mp4-advisory";
import { setCatalogIds } from "./src/lib/mp4-catalog";

const HOST = "127.0.0.1";
const PORT = Number.parseInt(process.env.BYETUNES_YOINK_PORT || "41337", 10);
const ISH_PORT = Number.parseInt(process.env.BYETUNES_ISH_PORT || "41339", 10);
const SHARED_ROOT = process.env.BYETUNES_SHARED_ROOT || join(process.cwd(), ".byetunes-local");
const MAX_BODY = 128 * 1024;

type ExecResult = { ok:boolean; ready?:boolean; exitCode?:number; timedOut?:boolean; stdout?:string; stderr?:string; error?:string };

function json(res:ServerResponse,status:number,body:unknown) {
  const data=Buffer.from(JSON.stringify(body));
  res.writeHead(status,{"Content-Type":"application/json","Content-Length":String(data.length),"Cache-Control":"no-store"});
  res.end(data);
}
function formatDuration(ms:number){const m=Math.floor(ms/60000),s=Math.floor((ms%60000)/1000);return String(m)+":"+s.toString().padStart(2,"0");}
function mapUnfurlTrack(track:SpotifyFromUrlTrack,collection:SpotifyFromUrlResponse["playlist_info"]):TrackInfo{
  const artist=track.artists.join("; ");
  const albumArtist=track.album_artists?.length?track.album_artists.join("; "):(collection.type==="album"||collection.type==="artist"?artist:null);
  return {name:track.name,artist,albumArtist,compilation:track.compilation??isCompilationAlbum(albumArtist),album:track.album,
    albumArt:track.image?.url||track.thumb_image?.url||collection.images[0]?.url||"",duration:formatDuration(track.duration_ms),
    durationMs:track.duration_ms,isrc:track.external_ids?.isrc||null,genre:null,releaseDate:track.release_date||collection.release_date||null,
    spotifyUrl:track.external_url,explicit:track.explicit,trackNumber:track.track_number,discNumber:track.disc_number,label:null,
    copyright:track.copyright||null,totalTracks:track.total_tracks??(collection.type==="album"?collection.total_tracks:null)};
}
function mapUnfurl(data:SpotifyFromUrlResponse){const tracks=data.tracks.map(t=>mapUnfurlTrack(t,data.playlist_info));if(data.playlist_info.type==="track")return tracks[0]?{type:"track",...tracks[0]}:null;return{type:"playlist",name:data.playlist_info.name,image:data.playlist_info.images[0]?.url||tracks[0]?.albumArt||"",tracks};}
async function readJSON(req:IncomingMessage):Promise<Record<string,unknown>>{const chunks:Buffer[]=[];let total=0;for await(const chunk of req){const b=Buffer.isBuffer(chunk)?chunk:Buffer.from(chunk);total+=b.length;if(total>MAX_BODY)throw new Error("request too large");chunks.push(b);}return chunks.length?JSON.parse(Buffer.concat(chunks).toString("utf8")):{};}

async function ishHealth(){try{const r=await fetch("http://127.0.0.1:"+ISH_PORT+"/health",{signal:AbortSignal.timeout(3000)});return{httpStatus:r.status,...await r.json() as Record<string,unknown>};}catch(e){return{ok:false,ready:false,error:e instanceof Error?e.message:String(e)};}}
async function ishExec(command:string,args:string[],cwd:string,timeoutMs=120000):Promise<ExecResult>{
  let lastError="iSH bridge unavailable";
  for(let attempt=0;attempt<120;attempt++){try{const r=await fetch("http://127.0.0.1:"+ISH_PORT+"/exec",{method:"POST",headers:{"Content-Type":"application/json"},body:JSON.stringify({command,args,cwd,timeoutMs}),signal:AbortSignal.timeout(timeoutMs+5000)});const result=await r.json() as ExecResult;if(r.status===503&&!result.ready){lastError=result.error||"iSH booting";await new Promise(x=>setTimeout(x,500));continue;}if(!r.ok||!result.ok)throw new Error(result.stderr||result.error||("HTTP "+r.status));return result;}catch(e){lastError=e instanceof Error?e.message:String(e);if(attempt<119)await new Promise(x=>setTimeout(x,500));}}
  throw new Error(lastError);
}

async function metadata(body:Record<string,unknown>){
  const url=body.url;if(!url||typeof url!=="string")return{status:400,body:{error:"URL is required"}};
  const platform=detectPlatform(url);if(!platform)return{status:400,body:{error:"paste a spotify, deezer, or apple music link"}};
  if(platform==="spotify"){const type=detectUrlType(url);const unfurled=await getSpotifyFromUrl(url,{enrichIsrc:true});if(unfurled){const mapped=mapUnfurl(unfurled);if(mapped)return{status:200,body:mapped};}
    if(type==="playlist"){const p=await getPlaylistInfo(url).catch(()=>resolvePlaylist(url));if(p)return{status:200,body:{type:"playlist",...p}};}
    else if(type==="album"){const a=await getAlbumInfo(url).catch(()=>resolveAlbum(url));if(a)return{status:200,body:{type:"playlist",...a}};}
    else if(type==="artist"){const a=await getArtistTopTracks(url).catch(()=>resolveArtist(url));if(a)return{status:200,body:{type:"playlist",...a}};}}
  const resolved=await resolveTrack(url);if(!resolved)return{status:404,body:{error:"couldn't find this track — try a different link"}};return{status:200,body:{type:"track",...resolved.track}};
}

function audioHeaders(audio:any,format:string,length:number,track:TrackInfo,lossless:boolean){
  const contentType=format==="m4a"?"audio/mp4":format==="flac"?"audio/flac":"audio/mpeg";
  const filename=encodeURIComponent(track.artist+" - "+track.name+" · yoink."+format);
  const h:Record<string,string>={"Content-Type":contentType,"Content-Disposition":"attachment; filename=\""+filename+"\"","Content-Length":String(length),"X-Audio-Source":audio.source,"X-Audio-Quality":lossless?"lossless":String(audio.bitrate),"X-Audio-Format":format,"Cache-Control":"no-store"};
  if(audio.qualityInfo){h["X-Audio-Codec"]=String(audio.qualityInfo.codec);h["X-Audio-Actual-Bitrate"]=String(audio.qualityInfo.bitrate);h["X-Audio-Sample-Rate"]=String(audio.qualityInfo.sampleRate);h["X-Audio-Channels"]=String(audio.qualityInfo.channels);if(audio.qualityInfo.bitDepth)h["X-Audio-Bit-Depth"]=String(audio.qualityInfo.bitDepth);h["X-Audio-Upscaled"]=String(audio.qualityInfo.isUpscaled);}
  if(audio.verification){h["X-Audio-Verified"]=String(audio.verification.verified);h["X-Audio-Verify-Confidence"]=String(audio.verification.confidence);}return h;
}

async function finishTrack(track:TrackInfo,body:Record<string,unknown>){
  const requestedFormat=typeof body.format==="string"?body.format.toLowerCase():"flac";
  const genreSource=typeof body.genreSource==="string"?body.genreSource:undefined;
  const syncedLyrics=body.syncedLyrics===true;
  const {audio,artBuffer,catalogIds,embeddedLyrics}=await prepareTrackAssets(track,{requestedFormat,genreSource,syncedLyrics});
  const preferLossless=requestedFormat==="flac"||requestedFormat==="alac";
  const canLossless=preferLossless&&(audio.source==="deezer"||audio.source==="tidal")&&audio.format==="flac";
  const wantAlac=canLossless&&requestedFormat==="alac",wantFlac=canLossless&&requestedFormat==="flac";
  const inputExt=audio.format==="flac"?"flac":"mp3",outputExt=wantAlac?"m4a":wantFlac?"flac":"mp3";
  await mkdir(SHARED_ROOT,{recursive:true});const jobName="job-"+randomUUID(),hostDir=join(SHARED_ROOT,jobName),guestDir="/mnt/byetunes/"+jobName;await mkdir(hostDir,{recursive:true});
  const inputHost=join(hostDir,"input."+inputExt),outputHost=join(hostDir,"output."+outputExt),artHost=join(hostDir,"cover.jpg");
  const inputGuest=guestDir+"/input."+inputExt,outputGuest=guestDir+"/output."+outputExt,artGuest=guestDir+"/cover.jpg";
  try{
    await writeFile(inputHost,audio.buffer);let hasArt=false;if(artBuffer){await writeFile(artHost,artBuffer);hasArt=true;}
    const args:string[]=["-i",inputGuest];if(hasArt)args.push("-i",artGuest,"-map","0:a","-map","1:0");
    if(wantAlac){args.push("-c:a","alac");if(hasArt)args.push("-c:v","copy","-disposition:v","attached_pic");}
    else if(wantFlac){args.push("-c:a",audio.format==="flac"?"copy":"flac");if(hasArt)args.push("-c:v","copy","-disposition:v","attached_pic");}
    else{const direct=audio.source==="deezer"&&audio.format==="mp3";args.push("-c:a",direct?"copy":"libmp3lame");if(!direct)args.push("-b:a","320k");if(hasArt)args.push("-c:v","copy","-id3v2_version","3","-metadata:s:v","title=Album cover","-metadata:s:v","comment=Cover (front)","-disposition:v","attached_pic");else args.push("-id3v2_version","3");}
    args.push("-metadata","title="+track.name,"-metadata","artist="+track.artist,"-metadata","album="+track.album);
    if(track.albumArtist)args.push("-metadata","album_artist="+track.albumArtist);if(track.compilation)args.push("-metadata","compilation=1");if(track.genre)args.push("-metadata","genre="+track.genre);if(track.releaseDate)args.push("-metadata","date="+track.releaseDate);
    if(track.trackNumber!=null)args.push("-metadata","track="+(track.totalTracks?String(track.trackNumber)+"/"+String(track.totalTracks):String(track.trackNumber)));
    if(track.discNumber!=null)args.push("-metadata","disc="+String(track.discNumber));if(track.isrc)args.push("-metadata",(wantAlac||wantFlac?"ISRC=":"TSRC=")+track.isrc);if(track.label)args.push("-metadata","label="+track.label);if(track.copyright)args.push("-metadata","copyright="+track.copyright);if(embeddedLyrics)args.push("-metadata","lyrics="+embeddedLyrics);
    if(wantAlac||wantFlac){const bitDepth=audio.qualityInfo?.bitDepth??16,sampleRate=audio.qualityInfo?.sampleRate??44100,codec=wantAlac?"ALAC":"FLAC";args.push("-metadata","comment=Lossless ("+codec+" "+bitDepth+"-bit/"+(sampleRate/1000).toFixed(1)+"kHz)");}
    args.push("-y",outputGuest);
    try{await ishExec("/usr/bin/ffmpeg",args,guestDir,120000);}catch{const fallback=wantAlac?["-y","-i",inputGuest,"-c:a","alac","-metadata","title="+track.name,"-metadata","artist="+track.artist,"-metadata","album="+track.album,outputGuest]:wantFlac?["-y","-i",inputGuest,"-c:a","flac","-metadata","title="+track.name,"-metadata","artist="+track.artist,"-metadata","album="+track.album,outputGuest]:["-y","-i",inputGuest,"-c:a","libmp3lame","-b:a","320k","-metadata","title="+track.name,"-metadata","artist="+track.artist,"-metadata","album="+track.album,outputGuest];try{await ishExec("/usr/bin/ffmpeg",fallback,guestDir,120000);}catch{return{buffer:audio.buffer,format:audio.format,headers:audioHeaders(audio,audio.format,audio.buffer.length,track,audio.format==="flac")};}}
    let finalBuffer=await readFile(outputHost);if(outputExt==="m4a"){if(track.explicit)finalBuffer=setExplicitTag(finalBuffer);if(catalogIds)finalBuffer=setCatalogIds(finalBuffer,catalogIds);}
    return{buffer:finalBuffer,format:outputExt,headers:audioHeaders(audio,outputExt,finalBuffer.length,track,(wantFlac||wantAlac)&&audio.format==="flac")};
  }finally{await rm(hostDir,{recursive:true,force:true}).catch(()=>{});}
}

async function download(body:Record<string,unknown>){
  const url=body.url;if(!url||typeof url!=="string")return{status:400,json:{error:"URL is required"}};
  const platform=detectPlatform(url);if(!platform)return{status:400,json:{error:"paste a spotify, deezer, or apple music link"}};
  const resolved=await resolveTrack(url);if(!resolved)return{status:404,json:{error:"couldn't find this track — try a different link"}};
  try{const finished=await finishTrack(resolved.track,body);return{status:200,audio:finished.buffer,headers:finished.headers};}catch(e){console.error("[ByeTunesLocal] download failed",e instanceof Error?e.message:String(e));return{status:500,json:{error:"download failed — please try again"}};}
}

function makeSilentWav(){const sampleRate=8000,samples=2000,dataSize=samples*2,out=Buffer.alloc(44+dataSize);out.write("RIFF",0);out.writeUInt32LE(36+dataSize,4);out.write("WAVE",8);out.write("fmt ",12);out.writeUInt32LE(16,16);out.writeUInt16LE(1,20);out.writeUInt16LE(1,22);out.writeUInt32LE(sampleRate,24);out.writeUInt32LE(sampleRate*2,28);out.writeUInt16LE(2,32);out.writeUInt16LE(16,34);out.write("data",36);out.writeUInt32LE(dataSize,40);return out;}
async function syntheticSelfTest(){await mkdir(SHARED_ROOT,{recursive:true});const jobName="selftest-"+randomUUID(),hostDir=join(SHARED_ROOT,jobName),guestDir="/mnt/byetunes/"+jobName;await mkdir(hostDir,{recursive:true});await writeFile(join(hostDir,"input.wav"),makeSilentWav());try{await ishExec("/usr/bin/ffmpeg",["-y","-i",guestDir+"/input.wav","-c:a","libmp3lame","-b:a","128k","-metadata","title=ByeTunes Local Self Test","-metadata","artist=Filza 27","-metadata","lyrics=[00:00.00]self test",guestDir+"/output.mp3"],guestDir,120000);await ishExec("/usr/bin/ffmpeg",["-y","-i",guestDir+"/input.wav","-c:a","flac","-metadata","title=ByeTunes Local Self Test","-metadata","artist=Filza 27","-metadata","lyrics=[00:00.00]self test",guestDir+"/output.flac"],guestDir,120000);const probe=await ishExec("/usr/bin/ffprobe",["-v","error","-show_entries","format=duration:format_tags=title,artist,lyrics","-of","json",guestDir+"/output.mp3"],guestDir,30000);const mp3=await readFile(join(hostDir,"output.mp3")),flac=await readFile(join(hostDir,"output.flac"));const tagsOkay=(probe.stdout||"").includes("ByeTunes Local Self Test")&&(probe.stdout||"").includes("Filza 27");return{passed:mp3.length>100&&flac.length>100&&tagsOkay,mp3Bytes:mp3.length,flacBytes:flac.length,tagsOkay,ffprobe:probe.stdout||""};}finally{await rm(hostDir,{recursive:true,force:true}).catch(()=>{});}}

async function handle(req:IncomingMessage,res:ServerResponse){
  if(req.method==="GET"&&req.url==="/health")return json(res,200,{ok:true,service:"byetunes-local-yoink",host:HOST,port:PORT,youtube:false,providers:["spotify","deezer","apple-music"],yoinkCommit:"061e33ffc8d5050f828196bb78f7034f817e1e2e",node:process.version,pid:process.pid,ish:await ishHealth()});
  if(req.method==="GET"&&req.url==="/internal/self-test"){try{const result=await syntheticSelfTest();return json(res,result.passed?200:500,result);}catch(e){return json(res,500,{passed:false,error:e instanceof Error?e.message:String(e)});}}
  if(req.method!=="POST"||(req.url!=="/api/metadata"&&req.url!=="/api/download"))return json(res,404,{error:"not found"});
  try{const body=await readJSON(req);if(req.url==="/api/metadata"){const result=await metadata(body);return json(res,result.status,result.body);}const result=await download(body);if("json"in result)return json(res,result.status,result.json);res.writeHead(result.status,result.headers);res.end(result.audio);}catch{return json(res,400,{error:"invalid request"});}
}
const server=http.createServer((req,res)=>{void handle(req,res);});
server.listen(PORT,HOST,()=>console.log("[ByeTunesLocal] ready http://"+HOST+":"+PORT));
