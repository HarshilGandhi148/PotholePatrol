import {MapContainer,TileLayer,CircleMarker,Tooltip,useMapEvents,useMap} from 'react-leaflet';
import {useEffect,useState} from 'react';
import type {PotholeReport} from '../types';
import 'leaflet/dist/leaflet.css';
export type Region='all'|'indy'|'fishers';
const bounds:Record<Region,[[number,number],[number,number]]>={all:[[39.755,-86.175],[39.995,-85.955]],indy:[[39.755,-86.175],[39.935,-86.045]],fishers:[[39.925,-86.065],[39.997,-85.95]]};
function Movement({region,pick}:{region:Region;pick?:[number,number]}){
 const map=useMap();const lat=pick?.[0],lng=pick?.[1];
 useEffect(()=>{
  const resize=()=>{map.invalidateSize({animate:false});if(lat!==undefined&&lng!==undefined)map.setView([lat,lng],Math.max(13,map.getZoom()),{animate:false});else map.fitBounds(bounds[region],{padding:[20,20],animate:false})};
  resize();const observer=new ResizeObserver(resize);observer.observe(map.getContainer());return ()=>observer.disconnect();
 },[map,region,lat,lng]);return null;
}
function Pick({onPick}:{onPick?:(lat:number,lng:number)=>void}){useMapEvents({click:e=>onPick?.(e.latlng.lat,e.latlng.lng)});return null}
export function RoadMap({reports,onSelect,onPick,region='all',selected}:{reports:PotholeReport[];onSelect?:(id:string)=>void;onPick?:(lat:number,lng:number)=>void;region?:Region;selected?:string}){const [failed,setFailed]=useState(false);return <div className="map-wrap"><MapContainer center={[39.9,-86.07]} zoom={11} zoomSnap={0.25} className="road-map"><Movement region={region} pick={onPick&&reports[0]?[reports[0].latitude,reports[0].longitude]:undefined}/><TileLayer attribution='&copy; OpenStreetMap contributors' url="https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png" eventHandlers={{tileerror:()=>setFailed(true)}}/><Pick onPick={onPick}/>{reports.map(r=><CircleMarker key={r.id} center={[r.latitude,r.longitude]} radius={selected===r.id?13:r.severity==='High'?9:7} pathOptions={{color:selected===r.id?'#17458a':'white',weight:selected===r.id?4:2,fillColor:{Open:'#d95151',Acknowledged:'#c78b24',Fixed:'#299b7e'}[r.status],fillOpacity:1}} eventHandlers={{click:()=>onSelect?.(r.id)}}><Tooltip>{r.address} · {r.severity}</Tooltip></CircleMarker>)}</MapContainer>{failed&&<div className="map-warning">Map tiles unavailable. Report markers remain interactive. Check your connection.</div>}<div className="legend"><span><i className="dot Open"/>Open</span><span><i className="dot Acknowledged"/>Acknowledged</span><span><i className="dot Fixed"/>Fixed / history</span></div></div>}
