import { useEffect, useState } from 'react';

import { accountsMyEmail, accountsMyNumber, accountsSavedLogin } from '@/core/accountsApi';

export interface AppAuthState {
    authed:        boolean;
    setAuthed:     (v: boolean) => void;
    authChecked:   boolean;
    justAuthed:    boolean;
    setJustAuthed: (v: boolean) => void;
    myNumber:      string | null;
    myEmail:       string | null;
    savedLogin:    { username: string; password: string } | null;
}

export function useAppAuth(appId: string, checkSession: () => Promise<boolean>): AppAuthState {
    const [authed,      setAuthed]      = useState(false);
    const [authChecked, setAuthChecked] = useState(false);
    const [justAuthed,  setJustAuthed]  = useState(false);
    const [myNumber,    setMyNumber]    = useState<string | null>(null);
    const [myEmail,     setMyEmail]     = useState<string | null>(null);
    const [savedLogin,  setSavedLogin]  = useState<{ username: string; password: string } | null>(null);

    useEffect(() => {
        void checkSession().then(ok => { setAuthed(ok); setAuthChecked(true); });
        void accountsMyNumber().then(setMyNumber);
        void accountsMyEmail().then(setMyEmail);
        void accountsSavedLogin(appId).then(setSavedLogin);
        // eslint-disable-next-line react-hooks/exhaustive-deps
    }, []);

    return { authed, setAuthed, authChecked, justAuthed, setJustAuthed, myNumber, myEmail, savedLogin };
}
