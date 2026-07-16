
export interface Post {
    id:     string;
    title:  string;
    body:   string;
    price?:  number;
    image?:  string;
    images?: string[];
    number: string;
    email?: string;
    date?:  string;
    mine?:  boolean;
}

export interface PostDraft {
    title:  string;
    body:   string;
    price?:  number;
    image?:  string;
    images?: string[];
    number: string;
    email?: string;
}

export const POSTS: Post[] = [
    {
        id: 'p1',
        title: 'Looking for a new job',
        body: 'I am looking for a new job in the field of software development. Reliable, experienced, references available.',
        number: '2135550148',
        date: 'Today, 11:18',
        mine: true,
    },
    {
        id: 'p2',
        title: 'Banshee Detailing Service',
        body: 'Professional mobile car detailing. I come to you, full valet inside and out. Banshee in the photo is my own.',
        image: "data:image/svg+xml;utf8," + encodeURIComponent("<svg xmlns='http://www.w3.org/2000/svg' width='200' height='200'><defs><linearGradient id='g' x1='0' y1='0' x2='1' y2='1'><stop offset='0' stop-color='#ef4444'/><stop offset='1' stop-color='#7f1d1d'/></linearGradient></defs><rect width='200' height='200' fill='url(#g)'/></svg>"),
        number: '2135550192',
        email: 'mike.banshee@lsmail.com',
        date: 'May 25th, 2026',
    },
    {
        id: 'p3',
        title: '2018+ Sanchez',
        body: 'Looking for a 2018 or newer model Sanchez. I am willing to pay a fair price for the right bike.',
        number: '3105550123',
        date: 'May 23rd, 2026',
    },
];
