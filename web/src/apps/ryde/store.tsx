import { createContext, useCallback, useContext, useEffect, useRef, useState } from 'react';
import type { ReactNode } from 'react';

import { useSessionState } from '@/hooks/useSessionState';
import { useNuiEvent } from '@/hooks/useNuiEvent';
import { isFiveM } from '@/core/nui';
import type { RydeRequestPush } from '@/core/types';
import { accountsMe, type AccountMe } from '@/core/accountsApi';
import {
    CAR_COLORS, clearRydeData, DEFAULT_DRIVER, distanceKm, DRIVERS, loadDriver, loadRides, loadState, newId, PLACES,
    resetLiveState, RIDER_NAMES, saveDriver, saveRides, saveState, startOfToday, suggestFare,
} from './data';
import type { DriverProfile, Place, Ride, RideOffer, RideStatus, RyderState } from './data';
import { ryde } from './rydeApi';
import type { RydeActiveRide } from './rydeApi';

resetLiveState();

type Tab = 'home' | 'activity' | 'driver' | 'leaderboard';

interface RydeCtx {
    rides: Ride[];
    driver: DriverProfile;
    state: RyderState;
    requests: Ride[];
    waitingCount: number;
    tab: Tab;
    activeRider: Ride | null;
    activeDriver: Ride | null;
    pendingRating: Ride | null;

    authChecked: boolean;
    authed: boolean;
    me: AccountMe | null;
    setAuth: (authed: boolean, me: AccountMe | null) => void;
    accountOpen: boolean;
    setAccountOpen: (v: boolean) => void;
    wipeAccount: () => void;

    setTab: (t: Tab) => void;
    setPayment: (p: 'card' | 'cash') => void;
    setSaved: (kind: 'home' | 'work', place: Place) => void;

    requestRide: (pickup: Place, dropoff: Place) => void;
    cancelRider: () => void;
    acceptOffer: () => void;
    declineOffer: () => void;
    switchOffer: () => void;
    submitRating: (stars: number, tip: number) => void;
    skipRating: () => void;

    becomeDriver: (car: string, plate: string, color: string) => void;
    unregisterDriver: () => void;
    setOnline: (v: boolean) => void;
    suggestPrice: (requestId: string, amount: number) => void;
    driverAdvance: () => void;
    driverCancel: () => void;
}

const Ctx = createContext<RydeCtx | null>(null);
export function useRyde(): RydeCtx { const c = useContext(Ctx); if (!c) throw new Error('useRyde'); return c; }

const ACTIVE: RideStatus[] = ['finding', 'offered', 'enroute_pickup', 'arriving', 'in_progress'];

function reqToRide(p: RydeRequestPush): Ride {
    return {
        id: p.id, role: 'driver',
        pickup:  { id: 'pk', name: p.pickup.label,  sub: '', x: p.pickup.x,  y: p.pickup.y },
        dropoff: { id: 'dp', name: p.dropoff.label, sub: '', x: p.dropoff.x, y: p.dropoff.y },
        distanceKm: p.distance, durationMin: Math.max(3, Math.round(p.distance * 2.4)), fare: 0,
        payment: 'card', status: 'finding', placedAt: p.createdAt, etaMin: 2 + Math.round(p.distance * 0.4),
        riderName: p.riderName,
    };
}

function mapStatus(s: string): RideStatus {
    return (s === 'declined' ? 'cancelled' : s) as RideStatus;
}

function showOffer(ride: Ride, tripId: string): Ride {
    const o = ride.offers?.find(x => x.tripId === tripId) ?? ride.offers?.[0];
    return o ? { ...ride, tripId: o.tripId, fare: o.fare, driver: o.driver } : ride;
}

function removeOffer(ride: Ride, tripId: string): Ride {
    const offers = (ride.offers ?? []).filter(o => o.tripId !== tripId);
    if (offers.length === 0) {
        return { ...ride, status: 'finding', offers: undefined, driver: undefined, fare: 0, tripId: undefined };
    }
    const shown = offers.some(o => o.tripId === ride.tripId) ? ride.tripId! : offers[0].tripId;
    return showOffer({ ...ride, offers }, shown);
}

function ptToPlace(p: { label: string; x: number; y: number }, id: string): Place {
    return { id, name: p.label || 'Location', sub: '', x: p.x, y: p.y };
}

function syncToRiderRide(a: RydeActiveRide, keepId?: string): Ride {
    const pickup = ptToPlace(a.pickup, 'pk');
    const dropoff = ptToPlace(a.dropoff, 'dp');
    const km = a.distance ?? distanceKm(pickup, dropoff);
    const offers: RideOffer[] = (a.offers ?? []).map(o => ({ tripId: o.tripId, fare: o.fare, driver: o.driver }));
    const ride: Ride = {
        id: keepId ?? a.id, role: 'rider', tripId: a.tripId,
        pickup, dropoff, distanceKm: km, durationMin: Math.max(3, Math.round(km * 2.4)),
        fare: a.fare ?? 0, payment: a.payment === 'cash' ? 'cash' : 'card',
        status: a.status as RideStatus, placedAt: a.createdAt ?? Date.now(),
        etaMin: 2 + Math.round(km * 0.4),
        driver: a.driver, offers: offers.length ? offers : undefined,
    };
    if (ride.status === 'offered' && offers.length) {
        return { ...ride, tripId: offers[0].tripId, fare: offers[0].fare, driver: offers[0].driver };
    }
    return ride;
}

function syncToDriverRide(a: RydeActiveRide, keepId?: string): Ride {
    const pickup = ptToPlace(a.pickup, 'pk');
    const dropoff = ptToPlace(a.dropoff, 'dp');
    const km = a.distance ?? distanceKm(pickup, dropoff);
    return {
        id: keepId ?? a.id, role: 'driver', tripId: a.tripId,
        pickup, dropoff, distanceKm: km, durationMin: Math.max(3, Math.round(km * 2.4)),
        fare: a.fare ?? 0, payment: a.payment === 'cash' ? 'cash' : 'card',
        status: a.status as RideStatus, placedAt: Date.now(), etaMin: 2 + Math.round(km * 0.4),
        riderName: a.riderName, riderNumber: a.riderNumber,
    };
}

function devRequest(seed = 0): Ride {
    const a = PLACES[(Math.floor(Date.now() / 1000) + seed) % PLACES.length];
    let b = PLACES[(Math.floor(Date.now() / 700) + seed * 3 + 1) % PLACES.length];
    if (b.id === a.id) b = PLACES[(PLACES.indexOf(a) + 1) % PLACES.length];
    const km = distanceKm(a, b);
    return {
        id: newId('req'), role: 'driver',
        pickup: a, dropoff: b, distanceKm: km, durationMin: Math.max(3, Math.round(km * 2.4)), fare: 0,
        payment: 'card', status: 'finding', placedAt: Date.now(), etaMin: 2 + Math.round(km * 0.4),
        riderName: RIDER_NAMES[(Math.floor(Date.now() / 1100) + seed) % RIDER_NAMES.length],
    };
}

export function RydeProvider({ children }: { children: ReactNode }) {
    const [rides, setRides] = useState<Ride[]>(() => loadRides());
    const [driver, setDriverState] = useState<DriverProfile>(() => loadDriver());
    const [state, setStateRaw] = useState<RyderState>(() => loadState());
    const [requests, setRequests] = useState<Ride[]>([]);
    const [waitingCount, setWaitingCount] = useState(0);
    const [tab, setTab] = useSessionState<Tab>('ryde:tab', 'home');
    const [accountOpen, setAccountOpen] = useState(false);
    const [pendingRatingId, setPendingRatingId] = useSessionState<string | null>('ryde:pendingRating', null);

    useEffect(() => {
        if ((tab as string) === 'account') setTab('home');
        // eslint-disable-next-line react-hooks/exhaustive-deps
    }, []);

    const [authChecked, setAuthChecked] = useState(false);
    const [authed, setAuthed] = useState(false);
    const [me, setMe] = useState<AccountMe | null>(null);
    useEffect(() => {
        void accountsMe('ryde').then(s => { setAuthed(s.loggedIn); setMe(s.me); setAuthChecked(true); });
    }, []);
    const setAuth = useCallback((a: boolean, m: AccountMe | null) => { setAuthed(a); setMe(m); }, []);

    const wipeAccount = useCallback(() => {
        clearRydeData();
        setRides([]);
        setDriverState({ ...DEFAULT_DRIVER });
        setStateRaw({ payment: 'card' });
        setRequests([]);
        setWaitingCount(0);
        setPendingRatingId(null);
        // eslint-disable-next-line react-hooks/exhaustive-deps
    }, []);

    useEffect(() => {
        if (!isFiveM) return;
        void ryde.waitingCount().then(d => { if (d) setWaitingCount(d.count); });
    }, []);

    useEffect(() => {
        if (!isFiveM) return;
        const atMount = loadRides();
        const riderRide  = atMount.find(r => r.role === 'rider'  && ACTIVE.includes(r.status));
        const driverRide = atMount.find(r => r.role === 'driver' && ACTIVE.includes(r.status));
        void ryde.sync().then(res => {
            if (!res) return;
            let next = loadRides();
            let dirty = false;
            const replaceOrAdd = (id: string | undefined, synced: Ride) => {
                next = (id && next.some(r => r.id === id)) ? next.map(r => r.id === id ? synced : r) : [synced, ...next];
                dirty = true;
            };
            if (res.rider) {
                replaceOrAdd(riderRide?.id, syncToRiderRide(res.rider, riderRide?.id));
            } else if (riderRide) {
                const ended = res.lastEnded;
                if (ended && ended.id === riderRide.tripId && ended.status === 'completed') {
                    next = next.map(r => r.id === riderRide.id ? { ...r, status: 'completed' as RideStatus, fare: ended.fare != null ? Number(ended.fare) : r.fare } : r);
                    setPendingRatingId(riderRide.id);
                } else {
                    next = next.map(r => r.id === riderRide.id ? { ...r, status: 'cancelled' as RideStatus } : r);
                }
                dirty = true;
            }
            if (res.driver) {
                replaceOrAdd(driverRide?.id, syncToDriverRide(res.driver, driverRide?.id));
            } else if (driverRide) {
                next = next.map(r => r.id === driverRide.id ? { ...r, status: 'cancelled' as RideStatus } : r);
                dirty = true;
            }
            if (res.requests) setRequests(res.requests.map(reqToRide));
            if (dirty) commitRides(next);
        });
        // eslint-disable-next-line react-hooks/exhaustive-deps
    }, []);

    const commitRides = useCallback((r: Ride[]) => { setRides(r); saveRides(r); }, []);
    const commitDriver = useCallback((d: DriverProfile) => { setDriverState(d); saveDriver(d); }, []);
    const setPayment = useCallback((p: 'card' | 'cash') => setStateRaw(s => { const n = { ...s, payment: p }; saveState(n); return n; }), []);
    const setSaved = useCallback((kind: 'home' | 'work', place: Place) => setStateRaw(s => { const n = { ...s, [kind]: place }; saveState(n); return n; }), []);

    const activeRider = rides.find(r => r.role === 'rider' && ACTIVE.includes(r.status)) ?? null;
    const activeDriver = rides.find(r => r.role === 'driver' && ACTIVE.includes(r.status)) ?? null;
    const pendingRating = rides.find(r => r.id === pendingRatingId) ?? null;

    const ridesRef = useRef(rides); ridesRef.current = rides;
    const driverRef = useRef(driver); driverRef.current = driver;
    const requestsRef = useRef(requests); requestsRef.current = requests;
    const waitingCountRef = useRef(waitingCount); waitingCountRef.current = waitingCount;

    const requestRide = useCallback((pickup: Place, dropoff: Place) => {
        const km = distanceKm(pickup, dropoff);
        const ride: Ride = {
            id: newId('ride'), role: 'rider',
            pickup, dropoff, distanceKm: km, durationMin: Math.max(3, Math.round(km * 2.4)),
            fare: 0, payment: state.payment, status: 'finding', placedAt: Date.now(), etaMin: 0,
        };
        commitRides([ride, ...loadRides()]);
        if (isFiveM) void ryde.requestRide({ label: dropoff.name, x: dropoff.x, y: dropoff.y });
    }, [state.payment, commitRides]);

    const cancelRider = useCallback(() => {
        if (isFiveM) void ryde.cancel();
        commitRides(loadRides().map(r => (r.role === 'rider' && ACTIVE.includes(r.status)) ? { ...r, status: 'cancelled' } : r));
    }, [commitRides]);

    const acceptOffer = useCallback(() => {
        const cur = loadRides();
        const offered = cur.find(r => r.role === 'rider' && r.status === 'offered');
        if (isFiveM && offered?.tripId) void ryde.respond(offered.tripId, true);
        commitRides(cur.map(r => (r.role === 'rider' && r.status === 'offered') ? { ...r, status: 'enroute_pickup', offers: undefined } : r));
    }, [commitRides]);
    const declineOffer = useCallback(() => {
        const cur = loadRides();
        const offered = cur.find(r => r.role === 'rider' && r.status === 'offered');
        if (isFiveM && offered?.tripId) void ryde.respond(offered.tripId, false);
        commitRides(cur.map(r => (r.role === 'rider' && r.status === 'offered' && r.tripId) ? removeOffer(r, r.tripId) : r));
    }, [commitRides]);
    const switchOffer = useCallback(() => {
        commitRides(loadRides().map(r => {
            if (r.role !== 'rider' || r.status !== 'offered' || (r.offers?.length ?? 0) < 2) return r;
            const offers = r.offers!;
            const idx = offers.findIndex(o => o.tripId === r.tripId);
            return showOffer(r, offers[(idx + 1) % offers.length].tripId);
        }));
    }, [commitRides]);

    const submitRating = useCallback((stars: number, tip: number) => {
        if (!pendingRatingId) return;
        const cur = loadRides();
        const ride = cur.find(r => r.id === pendingRatingId);
        if (isFiveM && ride?.tripId) void ryde.rate(ride.tripId, stars, tip);
        commitRides(cur.map(r => r.id === pendingRatingId ? { ...r, rated: stars, tip, fare: r.fare + tip } : r));
        setPendingRatingId(null);
    }, [pendingRatingId, commitRides]);
    const skipRating = useCallback(() => setPendingRatingId(null), [setPendingRatingId]);

    useEffect(() => {
        if (isFiveM) return;
        const t = window.setInterval(() => {
            const cur = ridesRef.current;
            let changed = false, completedId: string | null = null;
            const next = cur.map((r): Ride => {
                if (r.role !== 'rider' || !ACTIVE.includes(r.status)) return r;
                if (r.status === 'finding') {
                    changed = true;
                    const d = DRIVERS[Math.floor(r.placedAt) % DRIVERS.length];
                    const offer: RideOffer = { tripId: newId('off'), fare: suggestFare(r.distanceKm), driver: d };
                    return showOffer({ ...r, status: 'offered' as RideStatus, offers: [offer], etaMin: 2 + Math.round(r.distanceKm * 0.4) }, offer.tripId);
                }
                if (r.status === 'offered' && (r.offers?.length ?? 0) === 1) {
                    changed = true;
                    const d = DRIVERS[(Math.floor(r.placedAt) + 2) % DRIVERS.length];
                    const offer: RideOffer = { tripId: newId('off'), fare: suggestFare(r.distanceKm) + 3, driver: d };
                    return { ...r, offers: [...(r.offers ?? []), offer] };
                }
                if (r.status === 'enroute_pickup') { changed = true; return { ...r, status: 'arriving' }; }
                if (r.status === 'arriving') { changed = true; return { ...r, status: 'in_progress' }; }
                if (r.status === 'in_progress') { changed = true; completedId = r.id; return { ...r, status: 'completed' }; }
                return r;
            });
            if (changed) { setRides(next); saveRides(next); if (completedId) setPendingRatingId(completedId); }
        }, 5000);
        return () => window.clearInterval(t);
    }, []);

    const becomeDriver = useCallback((car: string, plate: string, color: string) => {
        commitDriver({ ...driver, enabled: true, car, plate, color: color || CAR_COLORS[0] });
    }, [driver, commitDriver]);
    const unregisterDriver = useCallback(() => {
        commitDriver({ ...driver, enabled: false, online: false, onlineSince: undefined });
        setRequests([]);
    }, [driver, commitDriver]);
    const setOnline = useCallback((v: boolean) => {
        commitDriver({ ...driver, online: v, onlineSince: v ? Date.now() : undefined });
        if (!v) {
            if (!isFiveM) setWaitingCount(requestsRef.current.length);
            setRequests([]);
            if (isFiveM) void ryde.setOnline(false).then(res => { if (res) setWaitingCount(res.waiting ?? 0); });
            return;
        }
        if (isFiveM) {
            void ryde.setOnline(true, { vehicle: driver.car, plate: driver.plate, color: driver.color }).then(res => {
                setRequests((res?.requests ?? []).map(reqToRide));
                if (res) setWaitingCount(res.waiting ?? res.requests?.length ?? 0);
            });
        } else {
            const n = Math.max(0, Math.min(5, waitingCountRef.current));
            setRequests(n > 0 ? Array.from({ length: n }, (_, i) => devRequest(i)) : []);
        }
    }, [driver, commitDriver]);

    const suggestPrice = useCallback((requestId: string, amount: number) => {
        const req = requestsRef.current.find(r => r.id === requestId);
        if (!req) return;
        setRequests(prev => prev.filter(r => r.id !== requestId));
        if (isFiveM) {
            void ryde.accept(req.id, amount).then(res => {
                commitRides([{ ...req, tripId: res?.tripId ?? req.id, status: 'offered', fare: amount }, ...loadRides()]);
            });
        } else {
            const ride: Ride = { ...req, status: 'offered', fare: amount };
            commitRides([ride, ...loadRides()]);
            window.setTimeout(() => {
                commitRides(loadRides().map(x => (x.id === ride.id && x.status === 'offered') ? { ...x, status: 'enroute_pickup' } : x));
            }, 3500);
        }
    }, [commitRides]);

    const driverAdvance = useCallback(() => {
        const cur = loadRides();
        const trip = cur.find(r => r.role === 'driver' && ACTIVE.includes(r.status));
        if (isFiveM && trip?.tripId) {
            if (trip.status === 'enroute_pickup') void ryde.tripStatus(trip.tripId, 'arriving');
            else if (trip.status === 'arriving') void ryde.tripStatus(trip.tripId, 'in_progress');
            else if (trip.status === 'in_progress') void ryde.complete(trip.tripId);
        }
        commitRides(cur.map((r): Ride => {
            if (r.role !== 'driver' || !ACTIVE.includes(r.status)) return r;
            if (r.status === 'enroute_pickup') return { ...r, status: 'arriving' };
            if (r.status === 'arriving') return { ...r, status: 'in_progress' };
            if (r.status === 'in_progress') {
                const earn = r.fare;
                commitDriver({ ...loadDriver(), trips: loadDriver().trips + 1, earningsTotal: Math.round((loadDriver().earningsTotal + earn) * 100) / 100, rating: Math.min(5, loadDriver().rating), ratingCount: loadDriver().ratingCount + 1 });
                return { ...r, status: 'completed', earn };
            }
            return r;
        }));
    }, [commitRides, commitDriver]);
    const driverCancel = useCallback(() => {
        const cur = loadRides();
        const trip = cur.find(r => r.role === 'driver' && ACTIVE.includes(r.status));
        if (isFiveM) void ryde.cancel();
        if (trip && trip.status === 'offered') {
            commitRides(cur.filter(r => r.id !== trip.id));
            if (!isFiveM) {
                setRequests(prev => prev.some(r => r.id === trip.id) ? prev
                    : [{ ...trip, role: 'driver', status: 'finding' as RideStatus, fare: 0 }, ...prev]);
            }
            return;
        }
        commitRides(cur.map(r => (r.role === 'driver' && ACTIVE.includes(r.status)) ? { ...r, status: 'cancelled' } : r));
    }, [commitRides]);

    const tick = useRef(0);
    useEffect(() => {
        if (isFiveM) return;
        const t = window.setInterval(() => {
            const d = driverRef.current;
            const busy = ridesRef.current.some(r => r.role === 'driver' && ACTIVE.includes(r.status));
            if (!d.online) {
                tick.current = 0;
                setWaitingCount(c => Math.min(5, Math.max(0, c + (Math.random() < 0.45 ? -1 : 1))));
                return;
            }
            if (busy) { tick.current = 0; return; }
            tick.current += 1;
            if (tick.current >= 2 && requestsRef.current.length < 4) {
                tick.current = 0;
                setRequests(prev => [devRequest(), ...prev]);
            }
        }, 4000);
        return () => window.clearInterval(t);
    }, []);

    useEffect(() => {
        if (isFiveM || !driver.online) return;
        setWaitingCount(requests.length);
    }, [requests, driver.online]);

    useNuiEvent('sd-phone:ryde:offer', useCallback((d) => {
        if (!d) return;
        const offer: RideOffer = {
            tripId: d.id, fare: d.fare ?? 0,
            driver: { name: d.driverName ?? 'Driver', car: d.vehicle ?? '', plate: d.plate ?? '', color: d.color ?? '#111', rating: d.rating ?? 5, number: d.number },
        };
        commitRides(loadRides().map(r => {
            if (r.role !== 'rider' || !(r.status === 'finding' || r.status === 'offered')) return r;
            const offers = [...(r.offers ?? []).filter(o => o.tripId !== offer.tripId), offer];
            const shown = r.status === 'offered' && r.tripId ? r.tripId : offer.tripId;
            return showOffer({ ...r, status: 'offered' as RideStatus, offers }, shown);
        }));
    }, [commitRides]));

    useNuiEvent('sd-phone:ryde:offerRemoved', useCallback((d) => {
        if (!d) return;
        commitRides(loadRides().map(r =>
            (r.role === 'rider' && r.status === 'offered' && (r.offers ?? []).some(o => o.tripId === d.id))
                ? removeOffer(r, d.id) : r));
    }, [commitRides]));

    useNuiEvent('sd-phone:ryde:tripUpdate', useCallback((d) => {
        if (!d) return;
        const st = mapStatus(d.status);
        let completedRiderId: string | null = null;
        commitRides(loadRides().map(r => {
            if (r.tripId !== d.id || r.role !== d.role) return r;
            if (d.role === 'rider' && st === 'completed') completedRiderId = r.id;
            return { ...r, status: st, offers: undefined,
                ...(d.fare != null ? { fare: d.fare } : {}),
                ...(d.earn != null ? { earn: d.earn } : {}),
                ...(d.role === 'driver' && d.number ? { riderNumber: d.number } : {}) };
        }));
        if (completedRiderId) setPendingRatingId(completedRiderId);
    }, [commitRides, setPendingRatingId]));

    useNuiEvent('sd-phone:ryde:ratingReceived', useCallback((d) => {
        if (!d || !d.id) return;
        commitRides(loadRides().map(r => (r.role === 'driver' && r.tripId === d.id)
            ? { ...r, rated: d.stars, ...(d.tip ? { tip: d.tip } : {}) } : r));
    }, [commitRides]));

    useNuiEvent('sd-phone:ryde:requestAdded', useCallback((d) => {
        if (d && driverRef.current.online) setRequests(prev => prev.some(r => r.id === d.id) ? prev : [reqToRide(d), ...prev]);
    }, []));
    useNuiEvent('sd-phone:ryde:requestRemoved', useCallback((d) => {
        if (d) setRequests(prev => prev.filter(r => r.id !== d.id));
    }, []));
    useNuiEvent('sd-phone:ryde:waitingCount', useCallback((d) => {
        if (d && typeof d.count === 'number') setWaitingCount(d.count);
    }, []));

    const value: RydeCtx = {
        rides, driver, state, requests, waitingCount, tab, activeRider, activeDriver, pendingRating,
        authChecked, authed, me, setAuth, accountOpen, setAccountOpen, wipeAccount,
        setTab, setPayment, setSaved, requestRide, cancelRider, acceptOffer, declineOffer, switchOffer, submitRating, skipRating,
        becomeDriver, unregisterDriver, setOnline, suggestPrice, driverAdvance, driverCancel,
    };
    return <Ctx.Provider value={value}>{children}</Ctx.Provider>;
}

export function driverStats(rides: Ride[]) {
    const done = rides.filter(r => r.role === 'driver' && r.status === 'completed');
    const today0 = startOfToday();
    const today = done.filter(r => r.placedAt >= today0);
    const sum = (a: Ride[]) => Math.round(a.reduce((s, r) => s + (r.earn ?? 0) + (r.tip ?? 0), 0) * 100) / 100;
    const rated = done.filter(r => r.rated != null);
    const avgRating = rated.length
        ? Math.round((rated.reduce((s, r) => s + (r.rated ?? 0), 0) / rated.length) * 100) / 100
        : null;
    return {
        tripsTotal: done.length,
        tripsToday: today.length,
        earnToday: sum(today),
        earnTotal: sum(done),
        avgRating,
        ratedCount: rated.length,
    };
}
