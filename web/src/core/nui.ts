
export const isFiveM = (() => {
    return typeof window !== 'undefined' && typeof (window as { GetParentResourceName?: () => string }).GetParentResourceName === 'function';
})();

const resourceName: string =
    isFiveM
        ? (window as unknown as { GetParentResourceName: () => string }).GetParentResourceName()
        : 'sd-phone';

export async function fetchNui<TResp = unknown>(event: string, payload?: unknown): Promise<TResp> {
    if (!isFiveM) {
        console.debug('[sd-phone:dev] fetchNui ->', event, payload);
        return { ok: true } as unknown as TResp;
    }

    const res = await fetch(`https://${resourceName}/${event}`, {
        method:  'POST',
        headers: { 'Content-Type': 'application/json; charset=UTF-8' },
        body:    JSON.stringify(payload ?? {}),
    });
    const text = await res.text();
    return (text ? JSON.parse(text) : {}) as TResp;
}
