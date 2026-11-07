import type {AnalysisResult,MediaAsset} from '../types';
async function preview(media:MediaAsset):Promise<AnalysisResult>{await new Promise(r=>setTimeout(r,900));return {demo:true,detections:[{detectionId:'sample-1',sourceMediaType:media.type,severitySuggestion:'High'}],suggestedSeverity:'High',suggestedDescription:'Sample description: visible pavement damage with a possible depression in the driving lane.',possibleDuplicates:['PP-1040'],recommendedAgency:'lafayette'}}
export const detectionService={analyzePhoto:preview,analyzeVideo:preview,getResults:preview};
