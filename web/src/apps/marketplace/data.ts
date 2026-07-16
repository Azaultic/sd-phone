
import bg3  from '@/assets/photos/background3.webp';
import bg6  from '@/assets/photos/background6.webp';
import bg9  from '@/assets/photos/background9.webp';
import bg11 from '@/assets/photos/background11.webp';

export interface Listing {
    id:     string;
    title:  string;
    body:   string;
    price?:  number;
    image?:  string;
    images?: string[];
    number: string;
    email?: string;
    date:   string;
    mine:   boolean;
}

export interface ListingDraft {
    title:  string;
    body:   string;
    price?:  number;
    image?:  string;
    images?: string[];
    number: string;
    email?: string;
}

export const LISTINGS: Listing[] = [
    {
        id: 'l1',
        title: 'X80 Proto',
        body: 'X80 Proto, white with red details. Has been driven carefully and is in mint condition.',
        price: 2_000_000,
        image: bg6,
        number: '2135550148',
        date: 'Today, 10:52',
        mine: true,
    },
    {
        id: 'l2',
        title: 'Banshee',
        body: 'Selling my 2020 model Bravado Banshee, low mileage and in perfect condition. Price is negotiable.',
        price: 74_999,
        image: bg9,
        number: '2135550192',
        email: 'mike.banshee@lsmail.com',
        date: 'May 25th, 2026',
        mine: false,
    },
    {
        id: 'l3',
        title: 'Sanchez, 2018 Model',
        body: 'Selling my 2018 Sanchez. It has low mileage and is in perfect condition. Price is negotiable.',
        price: 1_999,
        image: bg3,
        number: '3105550123',
        date: 'May 24th, 2026',
        mine: false,
    },
    {
        id: 'l4',
        title: 'Dominator',
        body: 'Vapid Dominator GTX, well maintained with a recent full service. Serious buyers only.',
        price: 38_500,
        image: bg11,
        number: '2135550174',
        date: 'May 22nd, 2026',
        mine: true,
    },
    {
        id: 'l5',
        title: 'Looking for a Faggio',
        body: 'In the market for a cheap runaround scooter. Condition is not important as long as it runs — cash waiting.',
        number: '3105550160',
        date: 'May 21st, 2026',
        mine: false,
    },
    {
        id: 'l6',
        title: 'Mechanic tools — full set',
        body: 'Complete socket and wrench set, barely used. Selling as I am leaving the city. Can deliver locally.',
        price: 850,
        number: '2135550133',
        date: 'May 20th, 2026',
        mine: false,
    },
];
