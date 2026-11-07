import {agencies} from '../adapters/mock';
export const agencyService={list:async()=>agencies,suggest:async()=>({agency:agencies[0],verified:false}),channel:async(id:string)=>agencies.find(a=>a.id===id)};
