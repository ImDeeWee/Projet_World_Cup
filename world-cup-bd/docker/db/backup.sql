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

--
-- Name: fn_donne_verifie_arbitre_principal(); Type: FUNCTION; Schema: public; Owner: wcuser
--

CREATE FUNCTION public.fn_donne_verifie_arbitre_principal() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_role type_role_arbitre;
BEGIN
    SELECT rolearbitre
      INTO v_role
      FROM arbitres
     WHERE id_arbitre = NEW.arbitre_id;

    IF v_role IS DISTINCT FROM 'Principal' THEN
        RAISE EXCEPTION
          'Arbitre % n''a pas le rôle ''Principal'' (actuel = %)',
          NEW.arbitre_id, v_role;
    END IF;

    RETURN NEW;
END;
$$;


ALTER FUNCTION public.fn_donne_verifie_arbitre_principal() OWNER TO wcuser;

--
-- Name: fn_faute_gestion_cartons(); Type: FUNCTION; Schema: public; Owner: wcuser
--

CREATE FUNCTION public.fn_faute_gestion_cartons() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE
    nb_jaunes  INT;
    existe_rouge BOOLEAN;
BEGIN
    /* Y a-t-il déjà un rouge pour ce joueur dans ce match ? */
    SELECT EXISTS (
        SELECT 1
          FROM faute
         WHERE joueur_id = NEW.joueur_id
           AND match_id  = NEW.match_id
           AND typefaute = 'Rouge'
    ) INTO existe_rouge;

    IF existe_rouge THEN
        RAISE EXCEPTION
          'Le joueur % a déjà un carton rouge pour le match %, insertion refusée',
          NEW.joueur_id, NEW.match_id;
    END IF;

    /* Si l’on ajoute un jaune, faut-il le transformer en rouge ? */
    IF NEW.typefaute = 'Jaune' THEN
        SELECT COUNT(*)
          INTO nb_jaunes
          FROM faute
         WHERE joueur_id = NEW.joueur_id
           AND match_id  = NEW.match_id
           AND typefaute = 'Jaune';

        IF nb_jaunes >= 1 THEN   -- c’est le 2ᵉ jaune
            NEW.typefaute := 'Rouge';
        END IF;
    END IF;

    RETURN NEW;
END;
$$;


ALTER FUNCTION public.fn_faute_gestion_cartons() OWNER TO wcuser;

--
-- Name: fn_sync_gagnant(); Type: FUNCTION; Schema: public; Owner: wcuser
--

CREATE FUNCTION public.fn_sync_gagnant() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_id_a       INT;
    v_id_b       INT;
    v_gagnant_id INT;
BEGIN
    /* 1) Récupère les infos du match visé */
    SELECT id_equipea,
           id_equipeb,
           gagnant_id
      INTO v_id_a,
           v_id_b,
           v_gagnant_id
      FROM matchs
     WHERE id_match = NEW.match_id;

    /* 2) Victoire de l’équipe A */
    IF NEW.pointequipea > NEW.pointequipeb THEN
        IF v_gagnant_id IS NULL OR v_gagnant_id = v_id_a THEN
            UPDATE matchs
               SET gagnant_id = v_id_a
             WHERE id_match  = NEW.match_id;
        ELSE
            RAISE EXCEPTION
              'Incohérence : gagnant_id=% mais pointequipea (%) > pointequipeb (%) pour match %',
              v_gagnant_id, NEW.pointequipea, NEW.pointequipeb, NEW.match_id;
        END IF;

    /* 3) Victoire de l’équipe B */
    ELSIF NEW.pointequipeb > NEW.pointequipea THEN
        IF v_gagnant_id IS NULL OR v_gagnant_id = v_id_b THEN
            UPDATE matchs
               SET gagnant_id = v_id_b
             WHERE id_match  = NEW.match_id;
        ELSE
            RAISE EXCEPTION
              'Incohérence : gagnant_id=% mais pointequipeb (%) > pointequipea (%) pour match %',
              v_gagnant_id, NEW.pointequipeb, NEW.pointequipea, NEW.match_id;
        END IF;

    /* 4) Match nul */
    ELSE  -- NEW.pointequipea = NEW.pointequipeb
        IF v_gagnant_id IS NOT NULL THEN
            RAISE EXCEPTION
              'Match nul : la colonne gagnant_id doit être NULL (match %)',
              NEW.match_id;
        END IF;
        -- Rien à faire si c’est déjà NULL
    END IF;

    RETURN NEW;      -- valide l'INSERT / UPDATE sur scorefinal
END;
$$;


ALTER FUNCTION public.fn_sync_gagnant() OWNER TO wcuser;

--
-- Name: fn_verifie_roles_arbitres(); Type: FUNCTION; Schema: public; Owner: wcuser
--

CREATE FUNCTION public.fn_verifie_roles_arbitres() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE
    r_principal  type_role_arbitre;
    r_assist1    type_role_arbitre;
    r_assist2    type_role_arbitre;
    r_assist3    type_role_arbitre;
BEGIN
    /* 2-a ► mêmes arbitres plusieurs fois ? */
    IF NEW.arbitre_principal_id IN (NEW.arbitre_secondaire1_id,
                                    NEW.arbitre_secondaire2_id,
                                    NEW.arbitre_secondaire3_id)
       OR NEW.arbitre_secondaire1_id IS NOT NULL
          AND NEW.arbitre_secondaire1_id IN (NEW.arbitre_secondaire2_id,
                                             NEW.arbitre_secondaire3_id)
       OR NEW.arbitre_secondaire2_id IS NOT NULL
          AND NEW.arbitre_secondaire2_id = NEW.arbitre_secondaire3_id
    THEN
        RAISE EXCEPTION
          'Le même arbitre ne peut pas être assigné plus d’une fois pour le match %',
          NEW.match_id;
    END IF;

    /* 2-b ► rôles conformes ? */
    SELECT rolearbitre INTO r_principal
      FROM arbitres WHERE id_arbitre = NEW.arbitre_principal_id;

    IF r_principal IS DISTINCT FROM 'Principal' THEN
        RAISE EXCEPTION
          'L’’arbitre % doit avoir le rôle Principal (actuel = %)',
          NEW.arbitre_principal_id, r_principal;
    END IF;

    SELECT rolearbitre INTO r_assist1
      FROM arbitres WHERE id_arbitre = NEW.arbitre_secondaire1_id;
    IF r_assist1 IS DISTINCT FROM 'Assistant' THEN
        RAISE EXCEPTION
          'L’’arbitre % doit avoir le rôle Assistant (actuel = %)',
          NEW.arbitre_secondaire1_id, r_assist1;
    END IF;

    SELECT rolearbitre INTO r_assist2
      FROM arbitres WHERE id_arbitre = NEW.arbitre_secondaire2_id;
    IF r_assist2 IS DISTINCT FROM 'Assistant' THEN
        RAISE EXCEPTION
          'L’’arbitre % doit avoir le rôle Assistant (actuel = %)',
          NEW.arbitre_secondaire2_id, r_assist2;
    END IF;

    SELECT rolearbitre INTO r_assist3
      FROM arbitres WHERE id_arbitre = NEW.arbitre_secondaire3_id;
    IF r_assist3 IS DISTINCT FROM 'Assistant' THEN
        RAISE EXCEPTION
          'L’’arbitre % doit avoir le rôle Assistant (actuel = %)',
          NEW.arbitre_secondaire3_id, r_assist3;
    END IF;

    RETURN NEW;                -- validation réussie
END;
$$;


ALTER FUNCTION public.fn_verifie_roles_arbitres() OWNER TO wcuser;

--
-- Name: joue_check_same_year(); Type: FUNCTION; Schema: public; Owner: wcuser
--

CREATE FUNCTION public.joue_check_same_year() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE
    anneeA INT;
    anneeB INT;
BEGIN
    -- récupérer l'année de chaque équipe
    SELECT anneecoupe INTO anneeA
    FROM   equipe
    WHERE  id_equipe = NEW.id_equipeA;

    SELECT anneecoupe INTO anneeB
    FROM   equipe
    WHERE  id_equipe = NEW.id_equipeB;

    -- si l'une des deux lignes n'existe pas, FK lèvera déjà l'erreur ;
    -- on vérifie seulement l'égalité
    IF anneeA IS DISTINCT FROM anneeB THEN
        RAISE EXCEPTION
          'Les équipes % et % ne participent pas à la même édition : % vs %',
          NEW.id_equipeA, NEW.id_equipeB, anneeA, anneeB;
    END IF;

    RETURN NEW;   -- tout est OK, on laisse passer
END;
$$;


ALTER FUNCTION public.joue_check_same_year() OWNER TO wcuser;

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
-- Name: donne; Type: TABLE; Schema: public; Owner: wcuser
--

CREATE TABLE public.donne (
    arbitre_id integer NOT NULL,
    faute_id integer NOT NULL
);


ALTER TABLE public.donne OWNER TO wcuser;

--
-- Name: entraine; Type: TABLE; Schema: public; Owner: wcuser
--

CREATE TABLE public.entraine (
    staff_id integer NOT NULL,
    id_equipe integer
);


ALTER TABLE public.entraine OWNER TO wcuser;

--
-- Name: equipe; Type: TABLE; Schema: public; Owner: wcuser
--

CREATE TABLE public.equipe (
    nompays character varying(30) NOT NULL,
    anneecoupe integer NOT NULL,
    id_capitaine integer,
    id_selectionneur integer,
    id_equipe integer NOT NULL
);


ALTER TABLE public.equipe OWNER TO wcuser;

--
-- Name: equipe_id_equipe_seq; Type: SEQUENCE; Schema: public; Owner: wcuser
--

CREATE SEQUENCE public.equipe_id_equipe_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.equipe_id_equipe_seq OWNER TO wcuser;

--
-- Name: equipe_id_equipe_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: wcuser
--

ALTER SEQUENCE public.equipe_id_equipe_seq OWNED BY public.equipe.id_equipe;


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
-- Name: gere; Type: TABLE; Schema: public; Owner: wcuser
--

CREATE TABLE public.gere (
    match_id integer NOT NULL,
    arbitre_principal_id integer,
    arbitre_secondaire1_id integer,
    arbitre_secondaire2_id integer,
    arbitre_secondaire3_id integer
);


ALTER TABLE public.gere OWNER TO wcuser;

--
-- Name: joue; Type: TABLE; Schema: public; Owner: wcuser
--

CREATE TABLE public.joue (
    id_match integer NOT NULL,
    id_equipea integer NOT NULL,
    id_equipeb integer NOT NULL,
    CONSTRAINT joue_check CHECK ((id_equipea <> id_equipeb))
);


ALTER TABLE public.joue OWNER TO wcuser;

--
-- Name: joueur; Type: TABLE; Schema: public; Owner: wcuser
--

CREATE TABLE public.joueur (
    id_joueur integer NOT NULL,
    numero integer,
    prenom character varying(50),
    nomfamille character varying(50),
    journ integer,
    moisn integer,
    annee integer,
    id_equipe integer
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
    rang public.type_rang NOT NULL,
    stade character varying(30) NOT NULL,
    arbitreprincipal_id integer,
    id_equipea integer,
    id_equipeb integer,
    gagnant_id integer,
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
-- Name: possede; Type: TABLE; Schema: public; Owner: wcuser
--

CREATE TABLE public.possede (
    equipe_id integer NOT NULL,
    joueur_id integer NOT NULL
);


ALTER TABLE public.possede OWNER TO wcuser;

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
    prenomstaff character varying(30),
    nomstaff character varying(30),
    journ integer,
    moisn integer,
    anneen integer,
    id_equipe integer
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
-- Name: equipe id_equipe; Type: DEFAULT; Schema: public; Owner: wcuser
--

ALTER TABLE ONLY public.equipe ALTER COLUMN id_equipe SET DEFAULT nextval('public.equipe_id_equipe_seq'::regclass);


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
-- Data for Name: donne; Type: TABLE DATA; Schema: public; Owner: wcuser
--

COPY public.donne (arbitre_id, faute_id) FROM stdin;
\.


--
-- Data for Name: entraine; Type: TABLE DATA; Schema: public; Owner: wcuser
--

COPY public.entraine (staff_id, id_equipe) FROM stdin;
\.


--
-- Data for Name: equipe; Type: TABLE DATA; Schema: public; Owner: wcuser
--

COPY public.equipe (nompays, anneecoupe, id_capitaine, id_selectionneur, id_equipe) FROM stdin;
\.


--
-- Data for Name: faute; Type: TABLE DATA; Schema: public; Owner: wcuser
--

COPY public.faute (faute_id, joueur_id, match_id, typefaute, faute_minute) FROM stdin;
\.


--
-- Data for Name: gere; Type: TABLE DATA; Schema: public; Owner: wcuser
--

COPY public.gere (match_id, arbitre_principal_id, arbitre_secondaire1_id, arbitre_secondaire2_id, arbitre_secondaire3_id) FROM stdin;
\.


--
-- Data for Name: joue; Type: TABLE DATA; Schema: public; Owner: wcuser
--

COPY public.joue (id_match, id_equipea, id_equipeb) FROM stdin;
\.


--
-- Data for Name: joueur; Type: TABLE DATA; Schema: public; Owner: wcuser
--

COPY public.joueur (id_joueur, numero, prenom, nomfamille, journ, moisn, annee, id_equipe) FROM stdin;
\.


--
-- Data for Name: matchs; Type: TABLE DATA; Schema: public; Owner: wcuser
--

COPY public.matchs (id_match, jourm, moism, rang, stade, arbitreprincipal_id, id_equipea, id_equipeb, gagnant_id) FROM stdin;
\.


--
-- Data for Name: possede; Type: TABLE DATA; Schema: public; Owner: wcuser
--

COPY public.possede (equipe_id, joueur_id) FROM stdin;
\.


--
-- Data for Name: scorefinal; Type: TABLE DATA; Schema: public; Owner: wcuser
--

COPY public.scorefinal (match_id, pointequipea, pointequipeb) FROM stdin;
\.


--
-- Data for Name: stafftechnique; Type: TABLE DATA; Schema: public; Owner: wcuser
--

COPY public.stafftechnique (id_staff, roleequipe, prenomstaff, nomstaff, journ, moisn, anneen, id_equipe) FROM stdin;
\.


--
-- Name: arbitres_id_arbitre_seq; Type: SEQUENCE SET; Schema: public; Owner: wcuser
--

SELECT pg_catalog.setval('public.arbitres_id_arbitre_seq', 1, false);


--
-- Name: equipe_id_equipe_seq; Type: SEQUENCE SET; Schema: public; Owner: wcuser
--

SELECT pg_catalog.setval('public.equipe_id_equipe_seq', 1, false);


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
-- Name: donne donne_pkey; Type: CONSTRAINT; Schema: public; Owner: wcuser
--

ALTER TABLE ONLY public.donne
    ADD CONSTRAINT donne_pkey PRIMARY KEY (arbitre_id, faute_id);


--
-- Name: entraine entraine_pkey; Type: CONSTRAINT; Schema: public; Owner: wcuser
--

ALTER TABLE ONLY public.entraine
    ADD CONSTRAINT entraine_pkey PRIMARY KEY (staff_id);


--
-- Name: equipe equipe_pkey; Type: CONSTRAINT; Schema: public; Owner: wcuser
--

ALTER TABLE ONLY public.equipe
    ADD CONSTRAINT equipe_pkey PRIMARY KEY (id_equipe);


--
-- Name: faute faute_pkey; Type: CONSTRAINT; Schema: public; Owner: wcuser
--

ALTER TABLE ONLY public.faute
    ADD CONSTRAINT faute_pkey PRIMARY KEY (faute_id);


--
-- Name: gere gere_pkey; Type: CONSTRAINT; Schema: public; Owner: wcuser
--

ALTER TABLE ONLY public.gere
    ADD CONSTRAINT gere_pkey PRIMARY KEY (match_id);


--
-- Name: joue joue_pkey; Type: CONSTRAINT; Schema: public; Owner: wcuser
--

ALTER TABLE ONLY public.joue
    ADD CONSTRAINT joue_pkey PRIMARY KEY (id_match);


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
-- Name: possede possede_pkey; Type: CONSTRAINT; Schema: public; Owner: wcuser
--

ALTER TABLE ONLY public.possede
    ADD CONSTRAINT possede_pkey PRIMARY KEY (equipe_id, joueur_id);


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
-- Name: donne trg_donne_verif_principal; Type: TRIGGER; Schema: public; Owner: wcuser
--

CREATE TRIGGER trg_donne_verif_principal BEFORE INSERT OR UPDATE ON public.donne FOR EACH ROW EXECUTE FUNCTION public.fn_donne_verifie_arbitre_principal();


--
-- Name: faute trg_faute_gestion_cartons; Type: TRIGGER; Schema: public; Owner: wcuser
--

CREATE TRIGGER trg_faute_gestion_cartons BEFORE INSERT OR UPDATE ON public.faute FOR EACH ROW EXECUTE FUNCTION public.fn_faute_gestion_cartons();


--
-- Name: joue trg_joue_same_year; Type: TRIGGER; Schema: public; Owner: wcuser
--

CREATE TRIGGER trg_joue_same_year BEFORE INSERT OR UPDATE ON public.joue FOR EACH ROW EXECUTE FUNCTION public.joue_check_same_year();


--
-- Name: scorefinal trg_sync_gagnant; Type: TRIGGER; Schema: public; Owner: wcuser
--

CREATE TRIGGER trg_sync_gagnant AFTER INSERT OR UPDATE ON public.scorefinal FOR EACH ROW EXECUTE FUNCTION public.fn_sync_gagnant();


--
-- Name: gere trg_verifie_roles_arbitres; Type: TRIGGER; Schema: public; Owner: wcuser
--

CREATE TRIGGER trg_verifie_roles_arbitres BEFORE INSERT OR UPDATE ON public.gere FOR EACH ROW EXECUTE FUNCTION public.fn_verifie_roles_arbitres();


--
-- Name: coupedumondeinfo coupedumondeinfo_annee_fkey; Type: FK CONSTRAINT; Schema: public; Owner: wcuser
--

ALTER TABLE ONLY public.coupedumondeinfo
    ADD CONSTRAINT coupedumondeinfo_annee_fkey FOREIGN KEY (annee) REFERENCES public.coupedumondehote(annee);


--
-- Name: donne donne_arbitre_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: wcuser
--

ALTER TABLE ONLY public.donne
    ADD CONSTRAINT donne_arbitre_id_fkey FOREIGN KEY (arbitre_id) REFERENCES public.arbitres(id_arbitre) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: donne donne_faute_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: wcuser
--

ALTER TABLE ONLY public.donne
    ADD CONSTRAINT donne_faute_id_fkey FOREIGN KEY (faute_id) REFERENCES public.faute(faute_id) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: entraine entraine_id_equipe_fkey; Type: FK CONSTRAINT; Schema: public; Owner: wcuser
--

ALTER TABLE ONLY public.entraine
    ADD CONSTRAINT entraine_id_equipe_fkey FOREIGN KEY (id_equipe) REFERENCES public.equipe(id_equipe);


--
-- Name: entraine entraine_staff_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: wcuser
--

ALTER TABLE ONLY public.entraine
    ADD CONSTRAINT entraine_staff_id_fkey FOREIGN KEY (staff_id) REFERENCES public.stafftechnique(id_staff) ON UPDATE CASCADE ON DELETE CASCADE;


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
-- Name: matchs fk_matchs_arbitre; Type: FK CONSTRAINT; Schema: public; Owner: wcuser
--

ALTER TABLE ONLY public.matchs
    ADD CONSTRAINT fk_matchs_arbitre FOREIGN KEY (arbitreprincipal_id) REFERENCES public.arbitres(id_arbitre);


--
-- Name: matchs fk_matchs_gagnant_equipe; Type: FK CONSTRAINT; Schema: public; Owner: wcuser
--

ALTER TABLE ONLY public.matchs
    ADD CONSTRAINT fk_matchs_gagnant_equipe FOREIGN KEY (gagnant_id) REFERENCES public.equipe(id_equipe) ON UPDATE CASCADE ON DELETE SET NULL;


--
-- Name: gere gere_arbitre_principal_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: wcuser
--

ALTER TABLE ONLY public.gere
    ADD CONSTRAINT gere_arbitre_principal_id_fkey FOREIGN KEY (arbitre_principal_id) REFERENCES public.arbitres(id_arbitre) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: gere gere_arbitre_secondaire1_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: wcuser
--

ALTER TABLE ONLY public.gere
    ADD CONSTRAINT gere_arbitre_secondaire1_id_fkey FOREIGN KEY (arbitre_secondaire1_id) REFERENCES public.arbitres(id_arbitre) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: gere gere_arbitre_secondaire2_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: wcuser
--

ALTER TABLE ONLY public.gere
    ADD CONSTRAINT gere_arbitre_secondaire2_id_fkey FOREIGN KEY (arbitre_secondaire2_id) REFERENCES public.arbitres(id_arbitre) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: gere gere_arbitre_secondaire3_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: wcuser
--

ALTER TABLE ONLY public.gere
    ADD CONSTRAINT gere_arbitre_secondaire3_id_fkey FOREIGN KEY (arbitre_secondaire3_id) REFERENCES public.arbitres(id_arbitre) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: gere gere_match_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: wcuser
--

ALTER TABLE ONLY public.gere
    ADD CONSTRAINT gere_match_id_fkey FOREIGN KEY (match_id) REFERENCES public.matchs(id_match) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: equipe id_equipe_selectionneur; Type: FK CONSTRAINT; Schema: public; Owner: wcuser
--

ALTER TABLE ONLY public.equipe
    ADD CONSTRAINT id_equipe_selectionneur FOREIGN KEY (id_selectionneur) REFERENCES public.stafftechnique(id_staff);


--
-- Name: joue joue_id_equipea_fkey; Type: FK CONSTRAINT; Schema: public; Owner: wcuser
--

ALTER TABLE ONLY public.joue
    ADD CONSTRAINT joue_id_equipea_fkey FOREIGN KEY (id_equipea) REFERENCES public.equipe(id_equipe) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: joue joue_id_equipeb_fkey; Type: FK CONSTRAINT; Schema: public; Owner: wcuser
--

ALTER TABLE ONLY public.joue
    ADD CONSTRAINT joue_id_equipeb_fkey FOREIGN KEY (id_equipeb) REFERENCES public.equipe(id_equipe) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: joue joue_id_match_fkey; Type: FK CONSTRAINT; Schema: public; Owner: wcuser
--

ALTER TABLE ONLY public.joue
    ADD CONSTRAINT joue_id_match_fkey FOREIGN KEY (id_match) REFERENCES public.matchs(id_match) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: joueur joueur_id_equipe_fkey; Type: FK CONSTRAINT; Schema: public; Owner: wcuser
--

ALTER TABLE ONLY public.joueur
    ADD CONSTRAINT joueur_id_equipe_fkey FOREIGN KEY (id_equipe) REFERENCES public.equipe(id_equipe);


--
-- Name: matchs matchs_id_equipea_fkey; Type: FK CONSTRAINT; Schema: public; Owner: wcuser
--

ALTER TABLE ONLY public.matchs
    ADD CONSTRAINT matchs_id_equipea_fkey FOREIGN KEY (id_equipea) REFERENCES public.equipe(id_equipe);


--
-- Name: matchs matchs_id_equipeb_fkey; Type: FK CONSTRAINT; Schema: public; Owner: wcuser
--

ALTER TABLE ONLY public.matchs
    ADD CONSTRAINT matchs_id_equipeb_fkey FOREIGN KEY (id_equipeb) REFERENCES public.equipe(id_equipe);


--
-- Name: possede possede_equipe_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: wcuser
--

ALTER TABLE ONLY public.possede
    ADD CONSTRAINT possede_equipe_id_fkey FOREIGN KEY (equipe_id) REFERENCES public.equipe(id_equipe);


--
-- Name: possede possede_joueur_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: wcuser
--

ALTER TABLE ONLY public.possede
    ADD CONSTRAINT possede_joueur_id_fkey FOREIGN KEY (joueur_id) REFERENCES public.joueur(id_joueur);


--
-- Name: scorefinal scorefinal_match_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: wcuser
--

ALTER TABLE ONLY public.scorefinal
    ADD CONSTRAINT scorefinal_match_id_fkey FOREIGN KEY (match_id) REFERENCES public.matchs(id_match);


--
-- Name: stafftechnique stafftechnique_id_equipe_fkey; Type: FK CONSTRAINT; Schema: public; Owner: wcuser
--

ALTER TABLE ONLY public.stafftechnique
    ADD CONSTRAINT stafftechnique_id_equipe_fkey FOREIGN KEY (id_equipe) REFERENCES public.equipe(id_equipe);


--
-- PostgreSQL database dump complete
--

