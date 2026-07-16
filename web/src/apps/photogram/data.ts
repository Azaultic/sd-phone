
import type { MsgKind, Reaction } from '@/shared/chat/data';
import { formatClockTime } from '@/lib/time';
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

export const IG = {
    blue: '#0095F6',   // verified badge / links / active tab
    red:  '#ED4956',   // likes
    sub:  '#737373',   // secondary text
    line: 'rgba(0,0,0,0.08)',
    ring: 'linear-gradient(45deg, #FEDA75, #FA7E1E 28%, #D62976 62%, #8134AF)',
};

export interface User { id: string; handle: string; avatar: string; verified?: boolean }

export interface Story { user: User; seen?: boolean; frames: string[] }

export interface Post {
    id:       string;
    user:     User;
    location?: string;
    images:   string[];
    caption:  string;
    likes:    number;
    liked?:   boolean;
    saved?:   boolean;
    comments: number;
    time:     string;
}

export interface Comment { id: string; user: User; text?: string; time: string; gifUrl?: string; likes?: number; liked?: boolean }

export interface Notif { id: string; user: User; text: string; time: string; thumb?: string; follow?: boolean }

export interface SharedPost { id: string; image: string; author: string; avatar?: string; caption?: string }

export interface DMsg  {
    id:         string;
    body:       string;
    at:         string;
    mine?:      boolean;
    ts?:        number;
    kind?:      MsgKind | 'post';
    gifUrl?:    string;
    duration?:  number;
    audioUrl?:  string;
    waveform?:  number[];
    reactions?: Reaction[];
    replyTo?:   { name: string; body: string };
    post?:      SharedPost;
}
export interface DM    { id: string; user: User; messages: DMsg[] }

const breze: User = { id: 'breze', handle: 'breze', avatar: bg4,  verified: true };
const loaf:  User = { id: 'loaf',  handle: 'loaf',  avatar: bg8 };
const mango: User = { id: 'mango', handle: 'mango_ls', avatar: bg9 };
const kai:   User = { id: 'kai',   handle: 'kai.exe', avatar: bg5, verified: true };
const vee:   User = { id: 'vee',   handle: 'vee', avatar: bg12 };

export const STORIES: Story[] = [
    { user: breze, frames: [bg6, bg11] },
    { user: kai,   frames: [bg5] },
    { user: mango, frames: [bg9, bg3] },
    { user: loaf,  seen: true, frames: [bg8] },
    { user: vee,   seen: true, frames: [bg12] },
];

export const POSTS: Post[] = [
    {
        id: 'p1', user: breze, location: 'Sandy Shores',
        images: [bg6, bg11], caption: 'sunsets are the best', likes: 2, comments: 0, time: 'Yesterday',
    },
    {
        id: 'p2', user: kai, location: 'Vinewood Hills',
        images: [bg5], caption: 'view from the top 🌃', likes: 184, comments: 12, time: '3 hours ago', liked: true,
    },
    {
        id: 'p3', user: mango, location: 'Del Perro Pier',
        images: [bg9, bg3, bg12], caption: 'beach day with the crew', likes: 57, comments: 4, time: '8 hours ago',
    },
    {
        id: 'p4', user: loaf,
        images: [bg8], caption: 'late night drive', likes: 23, comments: 1, time: '1 day ago',
    },
];

export const COMMENTS: Record<string, Comment[]> = {
    p2: [
        { id: 'p2c1', user: loaf,  text: 'unreal 🔥',            time: '2h',  likes: 4 },
        { id: 'p2c2', user: mango, text: 'where is this spot??', time: '1h'  },
        { id: 'p2c3', user: vee,   text: 'so clean',             time: '45m', likes: 1 },
    ],
    p3: [
        { id: 'p3c1', user: kai,   text: 'wish i was there', time: '6h' },
        { id: 'p3c2', user: breze, text: 'great crew 🙌',     time: '5h' },
    ],
    p4: [
        { id: 'p4c1', user: mango, text: 'night drives hit different', time: '20h' },
    ],
};

export const EXPLORE: string[] = [bg11, bg6, bg9, bg5, bg3, bg12, bg8, bg4, bg7, bg10, bg6, bg9, bg11, bg5, bg3];

export const ACTIVITY: Notif[] = [
    { id: 'n1', user: kai,   text: 'liked your photo.',              time: '2h', thumb: bg5 },
    { id: 'n2', user: loaf,  text: 'started following you.',         time: '5h', follow: true },
    { id: 'n3', user: breze, text: 'commented: "clean shot 🔥"',      time: '9h', thumb: bg6 },
    { id: 'n4', user: mango, text: 'and 12 others liked your photo.', time: '1d', thumb: bg9 },
    { id: 'n5', user: vee,   text: 'mentioned you in a comment.',     time: '2d', thumb: bg11 },
];

const dmNow = Date.now();
const H = 3_600_000, M = 60_000;
export const DMS: DM[] = [
    { id: 'd1', user: breze, messages: [
        { id: 'm1', body: 'yo that last post went hard', at: '14:02',              ts: dmNow - 2 * H },
        { id: 'm2', body: 'appreciate it 🙏',            at: '14:05', mine: true, ts: dmNow - 2 * H + 3 * M },
        { id: 'm3', body: 'where was it shot?',          at: '14:06',              ts: dmNow - 2 * H + 4 * M },
        { id: 'm4', body: '', at: '14:08', ts: dmNow - 2 * H + 6 * M, kind: 'post', post: { id: 'p3', image: bg9, author: 'mango_ls', avatar: bg9, caption: 'beach day with the crew — sun, sand and good vibes all afternoon long into the evening' } },
        { id: 'm5', body: 'check this one out', at: '14:09', mine: true, ts: dmNow - 2 * H + 7 * M, kind: 'post', post: { id: 'p2', image: bg5, author: 'kai.exe', avatar: bg5, caption: 'view from the top 🌃' } },
    ] },
    { id: 'd2', user: kai, messages: [
        { id: 'k1', body: 'sending the edit over now', at: '11:20', mine: true, ts: dmNow - 5 * H },
    ] },
    { id: 'd3', user: mango, messages: [
        { id: 'g1', body: 'beach day again this weekend?', at: 'Mon', ts: dmNow - 26 * H },
    ] },
];

export const MY_POSTS: string[] = [bg10, bg7, bg3, bg5, bg12, bg9];

export interface ProfileData { name: string; bio: string; avatar: string; private: boolean }

export function nowTime(): string {
    return formatClockTime(new Date(), true);
}
