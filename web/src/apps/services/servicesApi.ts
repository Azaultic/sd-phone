import { fetchNui, isFiveM } from '@/core/nui';
import { COMPANIES, EMPLOYEES, COMPANY_BALANCE, type Company, type Employee } from './data';
import { t } from '@/i18n';
import { apiData, type Envelope } from '@/core/api';


export interface Grade { level: number; label: string }

export interface MyCompany {
    job:        string;
    label:      string;
    isCompany?: boolean;
    isBoss:     boolean;
    available:  boolean;
    duty:       boolean;
    jobCalls:   boolean;
    jobMessages: boolean;
    myGrade?:   number;
    balance?:   number;
    grades?:    Grade[];
    employees?: Employee[];
}

export interface Directory {
    companies:  Company[];
    myCompany?: MyCompany | null;
    multijob?:  boolean;
    pendingOffers?: number;
}

interface MutResult { myCompany?: MyCompany | null }

export type ServiceResult = Envelope<MutResult>;

const DEV_MY_COMPANY: MyCompany = {
    job:       'police',
    label:     'Police',
    isCompany: true,
    isBoss:    true,
    available: true,
    duty:      true,
    jobCalls:  true,
    jobMessages: true,
    myGrade:   3,
    balance:   COMPANY_BALANCE,
    grades: [
        { level: 0, label: 'Recruit' }, { level: 1, label: 'Officer' },
        { level: 2, label: 'Sergeant' }, { level: 3, label: 'Lieutenant' },
    ],
    employees: EMPLOYEES,
};

const DEV_DIRECTORY: Directory = { companies: COMPANIES, myCompany: DEV_MY_COMPANY, multijob: true, pendingOffers: 1 };

export async function fetchDirectory(): Promise<Directory> {
    if (!isFiveM) return DEV_DIRECTORY;
    return (await apiData<Directory>('sd-phone:services:directory')) ?? { companies: [] };
}

async function mutate(event: string, payload?: unknown): Promise<ServiceResult> {
    if (!isFiveM) return { success: true, data: { myCompany: DEV_MY_COMPANY } };
    return (await fetchNui<ServiceResult>(event, payload))
        ?? { success: false, message: t('services.noResponse', 'No response from server') };
}

export const setDuty        = (on: boolean)             => mutate('sd-phone:services:setDuty', { on });
export const setJobCalls    = (on: boolean)             => mutate('sd-phone:services:setJobCalls', { on });
export const setJobMessages = (on: boolean)             => mutate('sd-phone:services:setJobMessages', { on });
export const deposit     = (amount: number)             => mutate('sd-phone:services:deposit', { amount });
export const withdraw    = (amount: number)             => mutate('sd-phone:services:withdraw', { amount });
export const hire        = (serverId: number, grade: number) => mutate('sd-phone:services:hire', { serverId, grade });
export const fire        = (citizenid: string)          => mutate('sd-phone:services:fire', { citizenid });
export const promote     = (citizenid: string)          => mutate('sd-phone:services:promote', { citizenid });
export const demote      = (citizenid: string)          => mutate('sd-phone:services:demote', { citizenid });
export const quitCompany = ()                           => mutate('sd-phone:services:quit');

export async function callCompany(job: string): Promise<ServiceResult> {
    if (!isFiveM) return { success: true };
    return (await fetchNui<ServiceResult>('sd-phone:services:callCompany', { job }))
        ?? { success: false, message: t('services.noResponse', 'No response from server') };
}

type ServiceMsgKind = 'text' | 'image' | 'location';

export interface InboxMessage {
    id:        string;
    from:      'me' | 'them';
    name?:     string;
    body:      string;
    ts:        number;
    kind?:     ServiceMsgKind;
    mediaUrl?: string;
    wpCode?:   string;
    wpSub?:    string;
}

export interface ServiceDraft {
    kind:      ServiceMsgKind;
    body:      string;
    mediaUrl?: string;
    wpCode?:   string;
    wpSub?:    string;
}
export interface InboxThread {
    key:      string;
    name:     string;
    color:    string;
    emoji:    string;
    preview:  string;
    ts:       number;
    unread:   number;
    messages: InboxMessage[];
}
export interface Inbox { personal: InboxThread[]; job: InboxThread[]; hasJob: boolean }

const DEV_INBOX: Inbox = {
    personal: [
        {
            key: 'police', name: 'Police', color: '#F2C94C', emoji: '🚓',
            preview: 'On our way.', ts: Date.now() - 60_000, unread: 1,
            messages: [
                { id: 'd1', from: 'me',   body: 'Is anyone available to help me?', ts: Date.now() - 120_000 },
                { id: 'd2', from: 'them', name: 'Officer Breze', body: 'On our way.', ts: Date.now() - 60_000 },
            ],
        },
    ],
    job: [
        {
            key: '5551234', name: 'John Doe', color: '#F2C94C', emoji: '🚓',
            preview: 'Is anyone available to help me?', ts: Date.now() - 120_000, unread: 2,
            messages: [{ id: 'd1', from: 'them', name: 'John Doe', body: 'Is anyone available to help me?', ts: Date.now() - 120_000 }],
        },
    ],
    hasJob: true,
};

export async function fetchInbox(): Promise<Inbox> {
    if (!isFiveM) return DEV_INBOX;
    return (await apiData<Inbox>('sd-phone:services:inbox')) ?? { personal: [], job: [], hasJob: false };
}

export async function messageCompany(job: string, draft: ServiceDraft): Promise<Inbox | null> {
    if (!isFiveM) return DEV_INBOX;
    return (await apiData<{ inbox: Inbox }>('sd-phone:services:messageCompany', { job, ...draft }))?.inbox ?? null;
}

export async function markThreadRead(scope: 'personal' | 'job', key: string): Promise<void> {
    if (!isFiveM) return;
    await fetchNui('sd-phone:services:markRead', { scope, key });
}

export async function replyCompany(citizen: string, draft: ServiceDraft): Promise<Inbox | null> {
    if (!isFiveM) return DEV_INBOX;
    return (await apiData<{ inbox: Inbox }>('sd-phone:services:replyCompany', { citizen, ...draft }))?.inbox ?? null;
}

export interface SavedJob {
    job:        string;
    label:      string;
    grade:      number;
    gradeLabel: string;
    active?:    boolean;
}
export interface JobInvite {
    id:         string;
    job:        string;
    label:      string;
    grade:      number;
    gradeLabel: string;
    from:       string;
}
export interface JobsView { multijob: boolean; jobs: SavedJob[]; invites: JobInvite[]; max: number }

const DEV_JOBS: JobsView = {
    multijob: true,
    max: 5,
    jobs: [
        { job: 'police',    label: 'Police',    grade: 3, gradeLabel: 'Lieutenant', active: true },
        { job: 'mechanic',  label: 'Mechanic',  grade: 1, gradeLabel: 'Apprentice' },
        { job: 'ambulance', label: 'Ambulance', grade: 0, gradeLabel: 'Trainee' },
    ],
    invites: [
        { id: 'd1', job: 'taxi', label: 'Taxi', grade: 0, gradeLabel: 'Driver', from: 'Tom Benson' },
    ],
};

export async function fetchJobs(): Promise<JobsView> {
    if (!isFiveM) return DEV_JOBS;
    return (await apiData<JobsView>('sd-phone:services:listJobs')) ?? { multijob: false, jobs: [], invites: [], max: 0 };
}

export type JobsResult = Envelope<JobsView>;
async function jobsMutate(event: string, payload?: unknown): Promise<JobsResult> {
    if (!isFiveM) return { success: true, data: DEV_JOBS };
    return (await fetchNui<JobsResult>(event, payload))
        ?? { success: false, message: t('services.noResponse', 'No response from server') };
}

export const switchJob     = (job: string) => jobsMutate('sd-phone:services:switchJob', { job });
export const removeJob     = (job: string) => jobsMutate('sd-phone:services:removeJob', { job });
export const acceptInvite  = (id: string)  => jobsMutate('sd-phone:services:acceptInvite', { id });
export const declineInvite = (id: string)  => jobsMutate('sd-phone:services:declineInvite', { id });
