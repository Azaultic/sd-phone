
import { t } from '@/i18n';
import type { Message } from '@/shared/chat/data';

import bg3  from '@/assets/photos/background3.webp';
import bg4  from '@/assets/photos/background4.webp';
import bg5  from '@/assets/photos/background5.webp';
import bg6  from '@/assets/photos/background6.webp';
import bg7  from '@/assets/photos/background7.webp';
import bg8  from '@/assets/photos/background8.webp';
import bg9  from '@/assets/photos/background9.webp';
import bg10 from '@/assets/photos/background10.webp';
import bg11 from '@/assets/photos/background11.webp';
import bg12 from '@/assets/photos/background12.webp';

export const CHERRY = {
    pink:  '#FF3D6E',   // primary accent / logo / sent bubbles
    nope:  '#FF4D5E',   // ✕ button
    rewind:'#FFA320',   // ↺ button
    like:  '#3CCB7F',   // ♥ button (reference heart is green)
};

export function msgPreview(m: Message): string {
    if (m.kind === 'image')    return t('cherry.previewPhoto', '📷 Photo');
    if (m.kind === 'gif')      return t('cherry.previewGif', 'GIF');
    if (m.kind === 'money')    return m.requested
        ? t('cherry.previewRequested', '💵 Requested ${amount}', { amount: m.amount ?? 0 })
        : t('cherry.previewMoney', '💵 ${amount}', { amount: m.amount ?? 0 });
    if (m.kind === 'voice')    return t('cherry.previewVoice', '🎤 Voice message');
    if (m.kind === 'location') return t('cherry.previewLocation', '📍 Location');
    return m.body;
}

export interface SwipeProfile {
    id:        string;
    name:      string;
    age:       number;
    gender?:   Gender;
    bio:       string;
    photos:    string[];
    likesYou?: boolean;
}

export type InterestedIn = 'Women' | 'Men' | 'Everyone';
export type Gender       = 'Man' | 'Woman' | 'Nonbinary';

export interface MyProfile {
    name:         string;
    age:          number;
    photos:       string[];
    about:        string;
    interestedIn: InterestedIn;
    gender:       Gender;
    visible:      boolean;
}

export interface MatchPartner {
    username: string;
    name:     string;
    age:      number;
    gender?:  Gender;
    photo?:   string;
    about?:   string;
    photos?:  string[];
}

export interface Match {
    id:           string;
    partner:      MatchPartner;
    messages:     Message[];
    loaded?:      boolean;
    createdAt?:   number;
}

export const PROFILES: SwipeProfile[] = [
    { id: 's1', name: 'Klara',   age: 25, gender: 'Woman',     bio: 'Member of Lost MC, looking for a good time.',           photos: [bg6, bg11, bg9], likesYou: true },
    { id: 's2', name: 'Sofia',   age: 23, gender: 'Woman',     bio: 'Vinewood hopeful. Buy me a coffee at the Bean Machine?', photos: [bg9, bg3] },
    { id: 's3', name: 'Mia',     age: 27, gender: 'Woman',     bio: "Mechanic by day. Don't ask about the nights.",           photos: [bg11, bg7], likesYou: true },
    { id: 's4', name: 'Aaliyah', age: 24, gender: 'Woman',     bio: "Paramedic — I'll fix your broken heart. Literally.",      photos: [bg5, bg12] },
    { id: 's5', name: 'Ivy',     age: 22, gender: 'Nonbinary', bio: 'Here for the views and the vibes. Mostly the views.',      photos: [bg3, bg8] },
    { id: 's6', name: 'Nova',    age: 26, gender: 'Nonbinary', bio: 'Spins records at the afterparties. Find me there.',        photos: [bg12, bg4], likesYou: true },
];

export const MY_PROFILE: MyProfile = {
    name:         'James',
    age:          25,
    photos:       [bg4, bg8, bg10],
    about:        "I'm a cool guy",
    interestedIn: 'Women',
    gender:       'Man',
    visible:      true,
};

const NOW = Date.now();
const MIN = 60_000;

export const MATCHES: Match[] = [
    {
        id: 'm1', loaded: true,
        partner: { username: 'klara', name: 'Klara', age: 25, gender: 'Woman', photo: bg6, photos: [bg6, bg11, bg9], about: 'Member of Lost MC, looking for a good time.' },
        messages: [
            { id: 'k1', from: 'klara', body: 'hey, saw you ride a Bati too 👀', kind: 'text', ts: NOW - 32 * MIN, read: true },
            { id: 'k2', from: 'me',    body: 'maybe. why, you racing?',         kind: 'text', ts: NOW - 28 * MIN, read: true },
            { id: 'k3', from: 'klara', body: 'always. tonight?',                kind: 'text', ts: NOW - 27 * MIN, read: true },
            { id: 'k4', from: 'me',    body: "i'm perfect, you look good!",     kind: 'text', ts: NOW - 20 * MIN, read: true },
        ],
    },
    {
        id: 'm2', loaded: true,
        partner: { username: 'mia', name: 'Mia', age: 27, gender: 'Woman', photo: bg11, photos: [bg11, bg7], about: "Mechanic by day. Don't ask about the nights." },
        messages: [
            { id: 'a1', from: 'mia', body: 'your car sounds rough, bring it by the shop', kind: 'text', ts: NOW - 130 * MIN, read: true },
        ],
    },
    {
        id: 'm3', loaded: true,
        partner: { username: 'nova', name: 'Nova', age: 26, photo: bg12 },
        messages: [],
    },
];
