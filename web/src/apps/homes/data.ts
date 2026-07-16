type HomeStatus = 'owned' | 'rented';

export interface Home {
    id:      string;
    address: string;
    type:    string;
    area:    string;
    value:   number;
    status:  HomeStatus;
    accent:  string;
    coords?: { x: number; y: number };
    locked?: boolean;
}

export interface KeyHolder { id: string; name: string }

export interface HomesCaps {
    lock:      boolean;
    keyList:   boolean;
    keyManage: boolean;
}

export const DEV_CAPS: HomesCaps = { lock: true, keyList: true, keyManage: true };

export const HOMES: Home[] = [
    { id: '1', address: 'Eclipse Towers, Apt 31',     type: 'Apartment', area: 'Vinewood',       value: 2400000, status: 'owned',  accent: '#5E5CE6', coords: { x: -777, y: 322 },  locked: true },
    { id: '2', address: '3671 Whispymound Drive',     type: 'Villa',     area: 'Vinewood Hills', value: 5300000, status: 'owned',  accent: '#0A84FF', coords: { x: 117, y: 559 },   locked: true },
    { id: '3', address: 'Del Perro Heights, Apt 4',   type: 'Apartment', area: 'Del Perro',      value: 1150000, status: 'owned',  accent: '#30B0C7', coords: { x: -1447, y: -538 }, locked: false },
    { id: '4', address: '2044 North Conker Avenue',   type: 'House',     area: 'Vinewood Hills', value: 4200000, status: 'owned',  accent: '#FF9500', coords: { x: 372, y: 416 },   locked: true },
    { id: '5', address: 'Mirror Park Bungalow',       type: 'House',     area: 'Mirror Park',    value:  890000, status: 'owned',  accent: '#34C759', coords: { x: 1311, y: -1495 }, locked: true },
    { id: '6', address: 'Paleto Bay Cabin',           type: 'Cabin',     area: 'Paleto Bay',     value:  420000, status: 'owned',  accent: '#FF3B30' },
];
