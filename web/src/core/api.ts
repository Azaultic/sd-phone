import { fetchNui } from './nui';

export interface Envelope<T = void> {
    success:  boolean;
    message?: string;
    data?:    T;
}

export async function apiCall<T>(event: string, payload?: unknown): Promise<Envelope<T>> {
    const res = await fetchNui<Envelope<T>>(event, payload);
    return res && typeof res.success === 'boolean' ? res : { success: false };
}

// Unwrap straight to the payload; null on failure. Use when the caller doesn't
// need the failure message.
export async function apiData<T>(event: string, payload?: unknown): Promise<T | null> {
    const res = await fetchNui<Envelope<T>>(event, payload);
    return res && res.success ? (res.data ?? null) : null;
}
