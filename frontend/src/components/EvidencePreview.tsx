import {useState} from 'react';
import {useApp} from '../state/context';
// Preview failure stays separate from detection results; unsupported codecs can still be replaced.
export function EvidencePreview(){const {media}=useApp();const [failed,setFailed]=useState(false);if(!media)return null;return <>{media.type==='photo'?<img className="media-preview" src={media.url} alt="Your selected road damage" onError={()=>setFailed(true)}/>:<video className="media-preview" src={media.url} controls playsInline onError={()=>setFailed(true)}/>}{failed&&<p className="error" role="alert">This browser cannot preview this media. Choose a supported image or video format.</p>}</>}
