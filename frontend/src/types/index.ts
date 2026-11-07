export type Severity = 'Low' | 'Medium' | 'High';
export type Status = 'Open' | 'Acknowledged' | 'Fixed';
export interface PriorityScore { total:number; severityContribution:number; observationContribution:number; safetyContribution:number; ageContribution:number }
export interface PotholeReport { id:string; latitude:number; longitude:number; address:string; severity:Severity; status:Status; description:string; agencyId:string; reportCount:number; createdAt:string; updatedAt:string; priorityScore:number; images:string[]; observations:string[]; source:'demo'|'local'; safetyHazard:boolean }
export interface DetectionResult { detectionId:string; sourceMediaType:'photo'|'video'; confidence?:number; severitySuggestion?:Severity; boundingBox?:number[]; frameTimestamp?:number; imageUrl?:string; latitude?:number; longitude?:number; description?:string }
export interface Agency { id:string; name:string; jurisdiction:string; reportingChannel:string; reportingUrl?:string; supportedSubmissionTypes:string[] }
export interface AnalysisResult { detections:DetectionResult[]; suggestedSeverity?:Severity; suggestedDescription?:string; suggestedLocation?:{address:string;latitude:number;longitude:number}; possibleDuplicates:string[]; recommendedAgency?:string; demo:boolean }
export interface SubmissionResult { success:boolean; localReportId?:string; agencyReferenceNumber?:string; status:'saved-locally'|'failed'|'submitted'; message:string }
export interface MediaAsset { file:File; url:string; type:'photo'|'video' }
export interface ReportDraft { address:string; latitude:string; longitude:string; severity:Severity; description:string; agencyId:string; safetyHazard:boolean }
