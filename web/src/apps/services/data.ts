import { formatMoney } from '@/lib/money';

export interface Company {
    id:          string;
    name:        string;
    location:    string;
    color:       string;
    emoji:       string;
    canCall:     boolean;
    callNumber?: string;
    coords?:     { x: number; y: number; z: number };
}

export interface Employee {
    id:     string;
    name:   string;
    rank:   string;
    online: boolean;
    status?: 'duty' | 'offduty' | 'away';
    grade?: number;
    self?:  boolean;
}

export const COMPANIES: Company[] = [
    { id: 'police',    name: 'Police',    location: 'Mission Row', color: '#0A84FF', emoji: '🚓', canCall: true,  callNumber: '911', coords: { x: 425.1,  y: -979.5,  z: 30.7 } },
    { id: 'ambulance', name: 'Ambulance', location: 'Pillbox',     color: '#C0392B', emoji: '🚑', canCall: true,  callNumber: '912', coords: { x: 307.7,  y: -1433.4, z: 29.9 } },
    { id: 'mechanic',  name: 'Mechanic',  location: 'LS Customs',  color: '#3A3A3C', emoji: '⚙️', canCall: false, coords: { x: -347.3, y: -133.8,  z: 39.0 } },
    { id: 'taxi',      name: 'Taxi',      location: 'Taxi HQ',     color: '#27AE60', emoji: '🚕', canCall: false, coords: { x: 895.7,  y: -179.3,  z: 74.7 } },
];

export const EMPLOYEES: Employee[] = [
    { id: 'e1', name: 'Breze',        rank: 'Officer',    online: true,  status: 'duty'    },
    { id: 'e2', name: 'Loaf Scripts', rank: 'Sergeant',   online: true,  status: 'offduty' },
    { id: 'e3', name: 'Kash',         rank: 'Lieutenant', online: false, status: 'away'    },
];

export const COMPANY_BALANCE = 1_000_000;

export function fmtMoney(n: number): string {
    return formatMoney(n, { whole: true });
}
