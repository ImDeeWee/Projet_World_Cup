--
-- PostgreSQL database dump
--

-- Dumped from database version 17.4 (Debian 17.4-1.pgdg120+2)
-- Dumped by pg_dump version 17.4 (Debian 17.4-1.pgdg120+2)

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET transaction_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

--
-- Name: roleequipe_type; Type: TYPE; Schema: public; Owner: wcuser
--

CREATE TYPE public.roleequipe_type AS ENUM (
    'selectionneur',
    'entraineurAdj',
    'entraineurGardien'
);


ALTER TYPE public.roleequipe_type OWNER TO wcuser;

--
-- Name: type_faute; Type: TYPE; Schema: public; Owner: wcuser
--

CREATE TYPE public.type_faute AS ENUM (
    'avertissement',
    'jaune',
    'rouge'
);


ALTER TYPE public.type_faute OWNER TO wcuser;

--
-- Name: type_rang; Type: TYPE; Schema: public; Owner: wcuser
--

CREATE TYPE public.type_rang AS ENUM (
    'phase de pool',
    '1/16',
    '1/8',
    '1/4',
    '1/2',
    'FinaleConsolation',
    'Finale'
);


ALTER TYPE public.type_rang OWNER TO wcuser;

--
-- Name: type_role_arbitre; Type: TYPE; Schema: public; Owner: wcuser
--

CREATE TYPE public.type_role_arbitre AS ENUM (
    'Principal',
    'Assistant'
);


ALTER TYPE public.type_role_arbitre OWNER TO wcuser;

SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: arbitres; Type: TABLE; Schema: public; Owner: wcuser
--

CREATE TABLE public.arbitres (
    id_arbitre integer NOT NULL,
    rolearbitre public.type_role_arbitre NOT NULL,
    prenom character varying(30) NOT NULL,
    nom character varying(30) NOT NULL
);


ALTER TABLE public.arbitres OWNER TO wcuser;

--
-- Name: arbitres_id_arbitre_seq; Type: SEQUENCE; Schema: public; Owner: wcuser
--

ALTER TABLE public.arbitres ALTER COLUMN id_arbitre ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.arbitres_id_arbitre_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: coupedumondehote; Type: TABLE; Schema: public; Owner: wcuser
--

CREATE TABLE public.coupedumondehote (
    annee integer NOT NULL,
    payshote character varying(100) NOT NULL
);


ALTER TABLE public.coupedumondehote OWNER TO wcuser;

--
-- Name: coupedumondeinfo; Type: TABLE; Schema: public; Owner: wcuser
--

CREATE TABLE public.coupedumondeinfo (
    annee integer NOT NULL,
    jourd integer,
    moisd integer,
    jourf integer,
    moisf integer,
    CONSTRAINT coupedumondeinfo_jourd_check CHECK (((jourd > 0) AND (jourd <= 31))),
    CONSTRAINT coupedumondeinfo_jourf_check CHECK (((jourf > 0) AND (jourf <= 31))),
    CONSTRAINT coupedumondeinfo_moisd_check CHECK (((moisd >= 1) AND (moisd <= 12))),
    CONSTRAINT coupedumondeinfo_moisf_check CHECK (((moisf >= 1) AND (moisf <= 12)))
);


ALTER TABLE public.coupedumondeinfo OWNER TO wcuser;

--
-- Name: equipe; Type: TABLE; Schema: public; Owner: wcuser
--

CREATE TABLE public.equipe (
    nompays character varying(30) NOT NULL,
    anneecoupe integer NOT NULL,
    id_capitaine integer,
    id_selectionneur integer
);


ALTER TABLE public.equipe OWNER TO wcuser;

--
-- Name: faute; Type: TABLE; Schema: public; Owner: wcuser
--

CREATE TABLE public.faute (
    faute_id integer NOT NULL,
    joueur_id integer,
    match_id integer,
    typefaute public.type_faute,
    faute_minute integer,
    CONSTRAINT faute_faute_minute_check CHECK (((faute_minute > 0) AND (faute_minute < 125)))
);


ALTER TABLE public.faute OWNER TO wcuser;

--
-- Name: faute_faute_id_seq; Type: SEQUENCE; Schema: public; Owner: wcuser
--

ALTER TABLE public.faute ALTER COLUMN faute_id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.faute_faute_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: joueur; Type: TABLE; Schema: public; Owner: wcuser
--

CREATE TABLE public.joueur (
    id_joueur integer NOT NULL,
    numero integer,
    nompays character varying(50),
    anneecoupe integer,
    prenom character varying(50),
    nomfamille character varying(50),
    journ integer,
    moisn integer,
    annee integer
);


ALTER TABLE public.joueur OWNER TO wcuser;

--
-- Name: joueur_id_joueur_seq; Type: SEQUENCE; Schema: public; Owner: wcuser
--

ALTER TABLE public.joueur ALTER COLUMN id_joueur ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.joueur_id_joueur_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: matchs; Type: TABLE; Schema: public; Owner: wcuser
--

CREATE TABLE public.matchs (
    id_match integer NOT NULL,
    jourm integer,
    moism integer,
    nompaysa character varying(30) NOT NULL,
    nompaysb character varying(30) NOT NULL,
    anneecoupe integer NOT NULL,
    rang public.type_rang NOT NULL,
    stade character varying(30) NOT NULL,
    gagnant character varying(30) NOT NULL,
    arbitreprincipal_id integer,
    CONSTRAINT matchs_check CHECK ((((gagnant)::text = (nompaysa)::text) OR ((gagnant)::text = (nompaysb)::text))),
    CONSTRAINT matchs_jourm_check CHECK (((jourm > 0) AND (jourm <= 31))),
    CONSTRAINT matchs_moism_check CHECK (((moism >= 1) AND (moism <= 12)))
);


ALTER TABLE public.matchs OWNER TO wcuser;

--
-- Name: matchs_id_match_seq; Type: SEQUENCE; Schema: public; Owner: wcuser
--

ALTER TABLE public.matchs ALTER COLUMN id_match ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.matchs_id_match_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: scorefinal; Type: TABLE; Schema: public; Owner: wcuser
--

CREATE TABLE public.scorefinal (
    match_id integer NOT NULL,
    pointequipea integer NOT NULL,
    pointequipeb integer NOT NULL
);


ALTER TABLE public.scorefinal OWNER TO wcuser;

--
-- Name: stafftechnique; Type: TABLE; Schema: public; Owner: wcuser
--

CREATE TABLE public.stafftechnique (
    id_staff integer NOT NULL,
    roleequipe public.roleequipe_type,
    nompays character varying(30) NOT NULL,
    anneecoupe integer NOT NULL,
    prenomstaff character varying(30),
    nomstaff character varying(30),
    journ integer,
    moisn integer,
    anneen integer
);


ALTER TABLE public.stafftechnique OWNER TO wcuser;

--
-- Name: stafftechnique_id_staff_seq; Type: SEQUENCE; Schema: public; Owner: wcuser
--

ALTER TABLE public.stafftechnique ALTER COLUMN id_staff ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.stafftechnique_id_staff_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Data for Name: arbitres; Type: TABLE DATA; Schema: public; Owner: wcuser
--

COPY public.arbitres (id_arbitre, rolearbitre, prenom, nom) FROM stdin;
\.


--
-- Data for Name: coupedumondehote; Type: TABLE DATA; Schema: public; Owner: wcuser
--

COPY public.coupedumondehote (annee, payshote) FROM stdin;
\.


--
-- Data for Name: coupedumondeinfo; Type: TABLE DATA; Schema: public; Owner: wcuser
--

COPY public.coupedumondeinfo (annee, jourd, moisd, jourf, moisf) FROM stdin;
\.


--
-- Data for Name: equipe; Type: TABLE DATA; Schema: public; Owner: wcuser
--

COPY public.equipe (nompays, anneecoupe, id_capitaine, id_selectionneur) FROM stdin;
\.


--
-- Data for Name: faute; Type: TABLE DATA; Schema: public; Owner: wcuser
--

COPY public.faute (faute_id, joueur_id, match_id, typefaute, faute_minute) FROM stdin;
\.


--
-- Data for Name: joueur; Type: TABLE DATA; Schema: public; Owner: wcuser
--

COPY public.joueur (id_joueur, numero, nompays, anneecoupe, prenom, nomfamille, journ, moisn, annee) FROM stdin;
\.


--
-- Data for Name: matchs; Type: TABLE DATA; Schema: public; Owner: wcuser
--

COPY public.matchs (id_match, jourm, moism, nompaysa, nompaysb, anneecoupe, rang, stade, gagnant, arbitreprincipal_id) FROM stdin;
\.


--
-- Data for Name: scorefinal; Type: TABLE DATA; Schema: public; Owner: wcuser
--

COPY public.scorefinal (match_id, pointequipea, pointequipeb) FROM stdin;
\.


--
-- Data for Name: stafftechnique; Type: TABLE DATA; Schema: public; Owner: wcuser
--

COPY public.stafftechnique (id_staff, roleequipe, nompays, anneecoupe, prenomstaff, nomstaff, journ, moisn, anneen) FROM stdin;
\.


--
-- Name: arbitres_id_arbitre_seq; Type: SEQUENCE SET; Schema: public; Owner: wcuser
--

SELECT pg_catalog.setval('public.arbitres_id_arbitre_seq', 1, false);


--
-- Name: faute_faute_id_seq; Type: SEQUENCE SET; Schema: public; Owner: wcuser
--

SELECT pg_catalog.setval('public.faute_faute_id_seq', 1, false);


--
-- Name: joueur_id_joueur_seq; Type: SEQUENCE SET; Schema: public; Owner: wcuser
--

SELECT pg_catalog.setval('public.joueur_id_joueur_seq', 1, false);


--
-- Name: matchs_id_match_seq; Type: SEQUENCE SET; Schema: public; Owner: wcuser
--

SELECT pg_catalog.setval('public.matchs_id_match_seq', 1, false);


--
-- Name: stafftechnique_id_staff_seq; Type: SEQUENCE SET; Schema: public; Owner: wcuser
--

SELECT pg_catalog.setval('public.stafftechnique_id_staff_seq', 1, false);


--
-- Name: arbitres arbitres_pkey; Type: CONSTRAINT; Schema: public; Owner: wcuser
--

ALTER TABLE ONLY public.arbitres
    ADD CONSTRAINT arbitres_pkey PRIMARY KEY (id_arbitre);


--
-- Name: coupedumondehote coupedumondehote_pkey; Type: CONSTRAINT; Schema: public; Owner: wcuser
--

ALTER TABLE ONLY public.coupedumondehote
    ADD CONSTRAINT coupedumondehote_pkey PRIMARY KEY (annee);


--
-- Name: coupedumondeinfo coupedumondeinfo_pkey; Type: CONSTRAINT; Schema: public; Owner: wcuser
--

ALTER TABLE ONLY public.coupedumondeinfo
    ADD CONSTRAINT coupedumondeinfo_pkey PRIMARY KEY (annee);


--
-- Name: equipe equipe_pkey; Type: CONSTRAINT; Schema: public; Owner: wcuser
--

ALTER TABLE ONLY public.equipe
    ADD CONSTRAINT equipe_pkey PRIMARY KEY (nompays, anneecoupe);


--
-- Name: faute faute_pkey; Type: CONSTRAINT; Schema: public; Owner: wcuser
--

ALTER TABLE ONLY public.faute
    ADD CONSTRAINT faute_pkey PRIMARY KEY (faute_id);


--
-- Name: joueur joueur_pkey; Type: CONSTRAINT; Schema: public; Owner: wcuser
--

ALTER TABLE ONLY public.joueur
    ADD CONSTRAINT joueur_pkey PRIMARY KEY (id_joueur);


--
-- Name: matchs matchs_pkey; Type: CONSTRAINT; Schema: public; Owner: wcuser
--

ALTER TABLE ONLY public.matchs
    ADD CONSTRAINT matchs_pkey PRIMARY KEY (id_match);


--
-- Name: scorefinal scorefinal_pkey; Type: CONSTRAINT; Schema: public; Owner: wcuser
--

ALTER TABLE ONLY public.scorefinal
    ADD CONSTRAINT scorefinal_pkey PRIMARY KEY (match_id);


--
-- Name: stafftechnique stafftechnique_pkey; Type: CONSTRAINT; Schema: public; Owner: wcuser
--

ALTER TABLE ONLY public.stafftechnique
    ADD CONSTRAINT stafftechnique_pkey PRIMARY KEY (id_staff);


--
-- Name: coupedumondeinfo coupedumondeinfo_annee_fkey; Type: FK CONSTRAINT; Schema: public; Owner: wcuser
--

ALTER TABLE ONLY public.coupedumondeinfo
    ADD CONSTRAINT coupedumondeinfo_annee_fkey FOREIGN KEY (annee) REFERENCES public.coupedumondehote(annee);


--
-- Name: faute faute_joueur_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: wcuser
--

ALTER TABLE ONLY public.faute
    ADD CONSTRAINT faute_joueur_id_fkey FOREIGN KEY (joueur_id) REFERENCES public.joueur(id_joueur);


--
-- Name: faute faute_match_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: wcuser
--

ALTER TABLE ONLY public.faute
    ADD CONSTRAINT faute_match_id_fkey FOREIGN KEY (match_id) REFERENCES public.matchs(id_match);


--
-- Name: joueur fk_joueur_equipe; Type: FK CONSTRAINT; Schema: public; Owner: wcuser
--

ALTER TABLE ONLY public.joueur
    ADD CONSTRAINT fk_joueur_equipe FOREIGN KEY (nompays, anneecoupe) REFERENCES public.equipe(nompays, anneecoupe);


--
-- Name: matchs fk_matchs_arbitre; Type: FK CONSTRAINT; Schema: public; Owner: wcuser
--

ALTER TABLE ONLY public.matchs
    ADD CONSTRAINT fk_matchs_arbitre FOREIGN KEY (arbitreprincipal_id) REFERENCES public.arbitres(id_arbitre);


--
-- Name: matchs fk_matchs_equipea; Type: FK CONSTRAINT; Schema: public; Owner: wcuser
--

ALTER TABLE ONLY public.matchs
    ADD CONSTRAINT fk_matchs_equipea FOREIGN KEY (nompaysa, anneecoupe) REFERENCES public.equipe(nompays, anneecoupe);


--
-- Name: matchs fk_matchs_equipeb; Type: FK CONSTRAINT; Schema: public; Owner: wcuser
--

ALTER TABLE ONLY public.matchs
    ADD CONSTRAINT fk_matchs_equipeb FOREIGN KEY (nompaysb, anneecoupe) REFERENCES public.equipe(nompays, anneecoupe);


--
-- Name: stafftechnique fk_staff_equipe; Type: FK CONSTRAINT; Schema: public; Owner: wcuser
--

ALTER TABLE ONLY public.stafftechnique
    ADD CONSTRAINT fk_staff_equipe FOREIGN KEY (nompays, anneecoupe) REFERENCES public.equipe(nompays, anneecoupe);


--
-- Name: equipe id_equipe_selectionneur; Type: FK CONSTRAINT; Schema: public; Owner: wcuser
--

ALTER TABLE ONLY public.equipe
    ADD CONSTRAINT id_equipe_selectionneur FOREIGN KEY (id_selectionneur) REFERENCES public.stafftechnique(id_staff);


--
-- Name: scorefinal scorefinal_match_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: wcuser
--

ALTER TABLE ONLY public.scorefinal
    ADD CONSTRAINT scorefinal_match_id_fkey FOREIGN KEY (match_id) REFERENCES public.matchs(id_match);


--
-- PostgreSQL database dump complete
--

