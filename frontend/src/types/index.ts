export type Severity = 'Low' | 'Medium' | 'High';
export type Status = 'Open' | 'Acknowledged' | 'Fixed';
export interface PriorityScore { total:number; severityContribution:number; observationContribution:number; safetyContribution:number; ageContribution:number }
export type DamageType = 'longitudinal_crack' | 'transverse_crack' | 'alligator_crack' | 'pothole';
export type DetectionSource = 'ios_coreml' | 'desktop' | 'backend' | 'demo';
export interface DetectionLocation { latitude:number; longitude:number; accuracyMeters?:number }
export interface PotholeReport { id:string; latitude:number; longitude:number; address:string; severity:Severity; status:Status; description:string; agencyId:string; reportCount:number; createdAt:string; updatedAt:string; priorityScore:number; images:string[]; observations:string[]; source:'demo'|'local'|'imported'; safetyHazard:boolean; demoRegion?:'indy'|'fishers'; damageType?:DamageType; detection?:DetectionResult; lifecycle?:'locally_prepared'|'officially_submitted'|'agency_resolved'|'repair_verified' }
export interface DetectionResult { detectionId:string; source:DetectionSource; className:DamageType; capturedAt:string; sessionId?:string; sourceMediaType:'photo'|'video'; confidence?:number; severitySuggestion?:Severity; boundingBox?:{x:number;y:number;width:number;height:number}; frameTimestampMs?:number; imageUrl?:string; location?:DetectionLocation; description?:string }
export interface Agency { id:string; name:string; jurisdiction:string; reportingChannel:string; reportingUrl?:string; supportedSubmissionTypes:string[] }
export interface AnalysisResult { detections:DetectionResult[]; suggestedSeverity?:Severity; suggestedDescription?:string; suggestedLocation?:{address:string;latitude:number;longitude:number}; possibleDuplicates:string[]; recommendedAgency?:string; demo:boolean }
export interface SubmissionResult { success:boolean; localReportId?:string; agencyReferenceNumber?:string; status:'saved-locally'|'failed'|'submitted'; message:string }
export interface MediaAsset { file:File; url:string; type:'photo'|'video' }
export interface ReportDraft { address:string; latitude:string; longitude:string; severity:Severity; description:string; agencyId:string; safetyHazard:boolean }
