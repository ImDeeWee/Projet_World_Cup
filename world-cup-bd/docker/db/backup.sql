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

SET default_tablespace = '';

SET default_table_access_method = heap;

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
-- Name: stafftechnique; Type: TABLE; Schema: public; Owner: wcuser
--

CREATE TABLE public.stafftechnique (
    id_staff integer NOT NULL,
    roleequipe character varying(30),
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
-- Data for Name: joueur; Type: TABLE DATA; Schema: public; Owner: wcuser
--

COPY public.joueur (id_joueur, numero, nompays, anneecoupe, prenom, nomfamille, journ, moisn, annee) FROM stdin;
\.


--
-- Data for Name: stafftechnique; Type: TABLE DATA; Schema: public; Owner: wcuser
--

COPY public.stafftechnique (id_staff, roleequipe, nompays, anneecoupe, prenomstaff, nomstaff, journ, moisn, anneen) FROM stdin;
\.


--
-- Name: joueur_id_joueur_seq; Type: SEQUENCE SET; Schema: public; Owner: wcuser
--

SELECT pg_catalog.setval('public.joueur_id_joueur_seq', 1, false);


--
-- Name: stafftechnique_id_staff_seq; Type: SEQUENCE SET; Schema: public; Owner: wcuser
--

SELECT pg_catalog.setval('public.stafftechnique_id_staff_seq', 1, false);


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
-- Name: joueur joueur_pkey; Type: CONSTRAINT; Schema: public; Owner: wcuser
--

ALTER TABLE ONLY public.joueur
    ADD CONSTRAINT joueur_pkey PRIMARY KEY (id_joueur);


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
-- Name: joueur fk_joueur_equipe; Type: FK CONSTRAINT; Schema: public; Owner: wcuser
--

ALTER TABLE ONLY public.joueur
    ADD CONSTRAINT fk_joueur_equipe FOREIGN KEY (nompays, anneecoupe) REFERENCES public.equipe(nompays, anneecoupe);


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
-- PostgreSQL database dump complete
--

