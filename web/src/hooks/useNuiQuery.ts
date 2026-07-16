import { useRef } from 'react';

import { apiData } from '@/core/api';
import { useAsyncData } from './useAsyncData';

// useAsyncData specialised for a raw NUI callback returning the standard
// { success, data } envelope. The payload is keyed by JSON value, so inline
// object literals don't refetch every render. NOTE: this bypasses app api
// helpers — if the app has dev-browser mocks in <app>Api.ts, wrap that helper
// with useAsyncData instead.
export function useNuiQuery<T>(event: string, opts?: {
    payload?: unknown;
    enabled?: boolean;
    onData?: (data: T) => void;
}): { data: T | null; loading: boolean; refetch: () => void } {
    const payloadRef = useRef(opts?.payload);
    payloadRef.current = opts?.payload;
    const payloadKey = JSON.stringify(opts?.payload ?? null);

    return useAsyncData<T>(
        () => apiData<T>(event, payloadRef.current),
        [event, payloadKey],
        { enabled: opts?.enabled, onData: opts?.onData },
    );
}
