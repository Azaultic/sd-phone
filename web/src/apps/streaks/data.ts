
export interface StreakPost {
    id:        number;
    author:    string;
    imageUrl:  string;
    caption?:  string;
    dayStreak: number;
    postDate:  string;
    createdAt: number;
    likeCount: number;
    likedByMe: boolean;
    isMine:    boolean;
}

export interface StreakState {
    current:        number;
    longest:        number;
    lastPostDate:   string | null;
    postedToday:    boolean;
    todayPost:      StreakPost | null;
    resetInSeconds: number;
}

export interface StreakMilestone { day: number; reward: number; }

export interface StreakConfig {
    milestones:       StreakMilestone[];
    rewardAccount:    string;
    maxCaptionLength: number;
}

export interface LeaderboardEntry {
    rank:    number;
    name:    string;
    current: number;
    isMe:    boolean;
}

export type StreakTab = 'me' | 'gallery' | 'board';


export const SEED_CONFIG: StreakConfig = {
    milestones: [
        { day: 1, reward: 100 },   { day: 3, reward: 250 },   { day: 5, reward: 500 },
        { day: 8, reward: 900 },   { day: 12, reward: 1500 }, { day: 16, reward: 2200 },
        { day: 21, reward: 3200 }, { day: 27, reward: 4500 }, { day: 34, reward: 6500 },
        { day: 42, reward: 9500 }, { day: 50, reward: 15000 },
    ],
    rewardAccount: 'bank',
    maxCaptionLength: 120,
};

export const SEED_GALLERY: StreakPost[] = [
    { id: 3, author: 'Mia Reyes',  imageUrl: 'https://picsum.photos/seed/streak3/600', caption: 'Sunset shift done.', dayStreak: 12, postDate: '2026-06-22', createdAt: 1750000000, likeCount: 8, likedByMe: false, isMine: false },
    { id: 2, author: 'Dao Tran',   imageUrl: 'https://picsum.photos/seed/streak2/600', caption: undefined,         dayStreak: 5,  postDate: '2026-06-22', createdAt: 1749990000, likeCount: 3, likedByMe: true,  isMine: false },
    { id: 1, author: 'You',        imageUrl: 'https://picsum.photos/seed/streak1/600', caption: 'Day one.',         dayStreak: 1,  postDate: '2026-06-21', createdAt: 1749900000, likeCount: 1, likedByMe: false, isMine: true },
];

export const SEED_STATE: StreakState = {
    current: 0,
    longest: 12,
    lastPostDate: '2026-06-21',
    postedToday: false,
    todayPost: null,
    resetInSeconds: 29640,
};

export const SEED_BOARD: LeaderboardEntry[] = [
    { rank: 1, name: 'Mia Reyes', current: 12, isMe: false },
    { rank: 2, name: 'Dao Tran',  current: 5,  isMe: false },
    { rank: 3, name: 'You',       current: 1,  isMe: true },
];
