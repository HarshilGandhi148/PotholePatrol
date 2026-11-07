import {createContext,useContext} from 'react';
import type {AppStore} from './store';
export const Context=createContext<AppStore|null>(null);
export function useApp(){const store=useContext(Context);if(!store)throw Error('App store provider is required');return store}
