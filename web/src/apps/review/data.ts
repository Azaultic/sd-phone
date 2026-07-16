
export interface Business {
    id:        string;
    name:      string;
    category:  string;
    address:   string;
    hours:     string;
    phone?:    string;
    blurb:     string;
    logo:      string;
    rating:    number;
    count:     number;
    myRating?: number;
    canManage?: boolean;
}

export interface BusinessEdit {
    id:    string;
    hours: string;
    blurb: string;
    logo:  string;
}

export interface Review {
    id:      string;
    author:  string;
    rating:  number;
    body:    string;
    image?:  string;
    date:    string;
    mine:    boolean;
    helpful: number;
    helped:  boolean;
}

export interface ReviewDraft {
    businessId: string;
    rating:     number;
    body:       string;
    image?:     string;
}
