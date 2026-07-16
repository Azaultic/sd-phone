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

export const ACCENT = '#FE2C55';

interface Creator {
    handle:    string;
    initials:  string;
    color:     string;
    verified?: boolean;
}

export interface VPost {
    id:       string;
    video:    string;
    creator:  Creator;
    caption:  string;
    sound:    string;
    time:     string;
    likes:    number;
    liked?:   boolean;
    comments: number;
    saves:    number;
    saved?:   boolean;
}

const luna:  Creator = { handle: 'luna.vibe',  initials: 'LV', color: '#7C3AED', verified: true };
const dex:   Creator = { handle: 'dex',        initials: 'DX', color: '#0EA5E9' };
const mira:  Creator = { handle: 'mira_ls',    initials: 'MR', color: '#F59E0B', verified: true };
const kobe:  Creator = { handle: 'kobe.rdr',   initials: 'KB', color: '#10B981' };
const sora:  Creator = { handle: 'sora',       initials: 'SO', color: '#EC4899', verified: true };
const nox:   Creator = { handle: 'nox404',     initials: 'NX', color: '#6366F1' };

export const PROFILE = {
    handle:    'you',
    name:      'You',
    initials:  'YO',
    color:     '#FE2C55',
    following: 128,
    followers: 4271,
    likes:     58300,
    bio:       'just vibing in los santos ✦',
};

export const POSTS: VPost[] = [
    {
        id: 'v1', video: bg6, creator: luna,
        caption: 'Trippy vibes 🌌 catch the sunset before it’s gone',
        sound: 'original sound — luna.vibe', time: '8h',
        likes: 16, comments: 1, saves: 1,
    },
    {
        id: 'v2', video: bg5, creator: dex,
        caption: 'view from the top never gets old 🌃',
        sound: 'Night Drive — synthwave', time: '3h',
        likes: 1243, comments: 88, saves: 42, liked: true,
    },
    {
        id: 'v3', video: bg9, creator: mira,
        caption: 'beach day with the whole crew ☀️ #lossantos',
        sound: 'original sound — mira_ls', time: '12h',
        likes: 5821, comments: 204, saves: 311,
    },
    {
        id: 'v4', video: bg8, creator: kobe,
        caption: 'late night drive, no destination',
        sound: 'lofi hours — chill beats', time: '1d',
        likes: 932, comments: 31, saves: 64,
    },
    {
        id: 'v5', video: bg11, creator: sora,
        caption: 'golden hour hits different up here ✨',
        sound: 'original sound — sora', time: '2d',
        likes: 28400, comments: 1290, saves: 2200, saved: true,
    },
    {
        id: 'v6', video: bg3, creator: nox,
        caption: 'found this spot at 3am 🔥 worth it',
        sound: 'Phonk Mix — nightcore', time: '4d',
        likes: 412, comments: 17, saves: 9,
    },
];

export interface DiscoverTile { id: string; img: string; views: number }

export const DISCOVER: DiscoverTile[] = [
    { id: 'd1',  img: bg11, views: 1200000 },
    { id: 'd2',  img: bg6,  views: 84200 },
    { id: 'd3',  img: bg9,  views: 5821 },
    { id: 'd4',  img: bg5,  views: 1243 },
    { id: 'd5',  img: bg3,  views: 920400 },
    { id: 'd6',  img: bg12, views: 33100 },
    { id: 'd7',  img: bg8,  views: 932 },
    { id: 'd8',  img: bg4,  views: 12700 },
    { id: 'd9',  img: bg7,  views: 460 },
    { id: 'd10', img: bg10, views: 2400000 },
    { id: 'd11', img: bg6,  views: 7800 },
    { id: 'd12', img: bg9,  views: 156000 },
];

export interface VNotif {
    id:       string;
    creator:  Creator;
    text:     string;
    time:     string;
    follow?:  boolean;
    thumb?:   string;
}

export const INBOX: VNotif[] = [
    { id: 'n1', creator: sora,  text: 'liked your video.',                 time: '2m', thumb: bg11 },
    { id: 'n2', creator: dex,   text: 'started following you.',            time: '18m', follow: true },
    { id: 'n3', creator: mira,  text: 'commented: "this is insane 🔥"',     time: '1h', thumb: bg9 },
    { id: 'n4', creator: kobe,  text: 'and 312 others liked your video.',  time: '3h', thumb: bg8 },
    { id: 'n5', creator: luna,  text: 'mentioned you in a comment.',       time: '6h', thumb: bg6 },
    { id: 'n6', creator: nox,   text: 'started following you.',            time: '1d', follow: true },
];

export const MY_POSTS: string[] = [bg10, bg7, bg3, bg5, bg12, bg9, bg11, bg6, bg4];

export function fmt(n: number): string {
    if (n < 1000) return String(n);
    if (n < 1_000_000) {
        const k = n / 1000;
        return (k < 10 ? k.toFixed(1).replace(/\.0$/, '') : Math.round(k)) + 'K';
    }
    const m = n / 1_000_000;
    return (m < 10 ? m.toFixed(1).replace(/\.0$/, '') : Math.round(m)) + 'M';
}
