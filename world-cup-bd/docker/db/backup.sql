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
    anneen integer,
    sexe character(1) DEFAULT 'M'::bpchar NOT NULL,
    CONSTRAINT joueur_sexe_check CHECK ((sexe = ANY (ARRAY['M'::bpchar, 'F'::bpchar])))
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
1930	Uruguay
1934	Italy
1938	France
1950	Brazil
1954	Switzerland
1958	Sweden
1962	Chile
1966	England
1970	Mexico
1974	West Germany
1978	Argentina
1982	Spain
1986	Mexico
1990	Italy
1994	United States
1998	France
2002	Japan & South Korea
2006	Germany
2010	South Africa
2014	Brazil
2018	Russia
2022	Qatar
\.


--
-- Data for Name: coupedumondeinfo; Type: TABLE DATA; Schema: public; Owner: wcuser
--

COPY public.coupedumondeinfo (annee, jourd, moisd, jourf, moisf) FROM stdin;
1930	13	7	30	7
1934	27	5	10	6
1938	4	6	19	6
1950	24	6	16	7
1954	16	6	4	7
1958	8	6	29	6
1962	30	5	17	7
1966	11	7	30	7
1970	31	5	21	6
1974	13	6	7	7
1978	1	6	25	6
1982	13	6	11	7
1986	31	5	29	6
1990	8	6	8	7
1994	17	6	17	7
1998	10	6	12	7
2002	31	5	30	6
2006	9	6	9	7
2010	11	6	11	7
2014	12	6	13	7
2018	14	6	15	7
2022	20	11	18	12
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

COPY public.joueur (id_joueur, numero, prenom, nomfamille, journ, moisn, anneen, sexe) FROM stdin;
69244	0	Ángel	Bossio	5	5	1905	M
23160	0	Juan	Botasso	23	10	1908	M
99230	0	Roberto	Cherro	23	2	1907	M
41921	0	Alberto	Chividini	23	2	1907	M
22739	0	José	Della Torre	23	3	1906	M
30720	0	Attilio	Demaría	19	3	1909	M
30543	0	Juan	Evaristo	20	6	1902	M
23897	0	Mario	Evaristo	10	12	1908	M
60505	0	Manuel	Ferreira	22	10	1905	M
25760	0	Luis	Monti	15	5	1901	M
49556	0	Ramón	Muttis	12	3	1899	M
91238	0	Rodolfo	Orlandini	1	1	1905	M
58537	0	Fernando	Paternoster	24	5	1903	M
24312	0	Natalio	Perinetti	28	12	1900	M
70166	0	Carlos	Peucelle	13	9	1908	M
49151	0	Edmundo	Piaggio	3	10	1905	M
44916	0	Alejandro	Scopelli	12	5	1908	M
21441	0	Carlos	Spadaro	5	2	1902	M
56486	0	Guillermo	Stábile	17	1	1905	M
56908	0	Arico	Suárez	5	6	1908	M
37326	0	Francisco	Varallo	5	2	1910	M
76546	0	Adolfo	Zumelzú	5	1	1902	M
92795	0	Ferdinand	Adams	3	5	1903	M
20690	0	Arnold	Badjou	26	6	1909	M
40714	0	Pierre	Braine	26	10	1900	M
41990	0	Alexis	Chantraine	16	3	1901	M
97126	0	Jean	De Bie	9	5	1892	M
93713	0	Jean	De Clercq	17	5	1905	M
41710	0	Henri	De Deken	3	8	1907	M
45315	0	Gérard	Delbeke	1	9	1903	M
16891	0	Jan	Diddens	14	9	1908	M
61253	0	August	Hellemans	14	9	1907	M
44475	0	Nic	Hoydonckx	29	12	1900	M
74839	0	Jacques	Moeschal	6	9	1900	M
46390	0	Theodore	Nouwens	17	2	1908	M
28503	0	André	Saeys	20	2	1911	M
69286	0	Louis	Versyp	5	12	1908	M
85443	0	Bernard	Voorhoof	10	5	1910	M
43807	0	Mario	Alborta	19	9	1910	M
62751	0	Juan	Argote	25	11	1906	M
95008	0	Jesús	Bermúdez	24	1	1902	M
97354	0	Miguel	Brito	13	6	1901	M
16019	0	José	Bustamante	1	1	1907	M
36835	0	Casiano	Chavarría	3	8	1901	M
69877	0	Segundo	Durandal	17	3	1912	M
61667	0	René	Fernández	1	1	1906	M
48216	0	Gumercindo	Gómez	21	1	1907	M
92600	0	Diógenes	Lara	6	4	1903	M
84833	0	Rafael	Méndez	1	1	1904	M
92838	0	Miguel	Murillo	24	3	1898	M
93364	0	Constantino	Noya	\N	\N	\N	M
56114	0	Eduardo	Reyes Ortiz	1	1	1907	M
35684	0	Luis	Reyes Peñaranda	5	6	1911	M
369	0	Renato	Sáinz	14	12	1899	M
67934	0	Jorge	Valderrama	12	12	1906	M
13299	0	not applicable	Araken	17	7	1905	M
70170	0	not applicable	Benedicto	30	10	1906	M
11648	0	not applicable	Benvenuto	4	8	1903	M
81166	0	not applicable	Brilhante	5	11	1904	M
58460	0	not applicable	Doca	7	4	1903	M
52323	0	not applicable	Fausto	28	1	1905	M
708	0	not applicable	Fernando	1	3	1906	M
49818	0	not applicable	Fortes	9	9	1901	M
29865	0	not applicable	Hermógenes	4	11	1908	M
92427	0	not applicable	Itália	22	5	1907	M
16656	0	not applicable	Joel	1	5	1904	M
72889	0	Carvalho	Leite	25	6	1912	M
30679	0	not applicable	Manoelzinho	22	8	1907	M
49633	0	Ivan	Mariz	16	5	1910	M
83987	0	not applicable	Moderato	14	7	1902	M
10526	0	not applicable	Nilo	3	4	1903	M
52064	0	not applicable	Oscarino	17	1	1907	M
32535	0	not applicable	Pamplona	24	3	1904	M
38379	0	not applicable	Poly	26	1	1909	M
91171	0	not applicable	Preguinho	8	2	1905	M
82422	0	not applicable	Russinho	18	12	1902	M
26796	0	not applicable	Teóphilo	11	4	1900	M
28745	0	not applicable	Velloso	25	9	1908	M
22493	0	not applicable	Zé Luiz	16	11	1904	M
95800	0	Juan	Aguilera	23	10	1903	M
33635	0	Guillermo	Arellano	21	8	1908	M
54301	0	Ernesto	Chaparro	4	1	1901	M
88235	0	Arturo	Coddou	14	1	1905	M
1278	0	Roberto	Cortés	2	2	1905	M
41928	0	Humberto	Elgueta	10	9	1904	M
32614	0	César	Espinoza	28	9	1900	M
7122	0	Víctor	Morales	10	5	1905	M
66860	0	Horacio	Muñoz	1	1	1900	M
19195	0	Tomás	Ojeda	20	4	1910	M
97943	0	Ulises	Poirier	2	2	1897	M
85142	0	Guillermo	Riveros	10	2	1902	M
49261	0	Guillermo	Saavedra	5	11	1903	M
89829	0	Carlos	Schneeberger	21	6	1902	M
8459	0	Guillermo	Subiabre	25	2	1902	M
10927	0	Arturo	Torres	20	10	1906	M
28795	0	Casimiro	Torres	1	1	1906	M
61338	0	Carlos	Vidal	24	2	1902	M
65664	0	Eberardo	Villalobos	1	4	1908	M
68817	0	Numa	Andoire	19	3	1908	M
77318	0	Marcel	Capelle	11	12	1904	M
83054	0	Augustin	Chantrel	11	11	1906	M
10604	0	Edmond	Delfour	1	11	1907	M
53878	0	Célestin	Delmer	15	2	1907	M
99087	0	Marcel	Langiller	2	6	1908	M
73308	0	Jean	Laurent	30	12	1906	M
5470	0	Lucien	Laurent	10	12	1907	M
89688	0	Ernest	Libérati	22	3	1906	M
60620	0	André	Maschinot	28	6	1903	M
67332	0	Étienne	Mattler	25	12	1905	M
58728	0	Marcel	Pinel	8	7	1908	M
62322	0	André	Tassin	24	12	1902	M
50248	0	Alex	Thépot	30	7	1906	M
2281	0	Émile	Veinante	12	6	1907	M
48345	0	Alexandre	Villaplane	24	12	1904	M
36379	0	Efraín	Amézcua	3	8	1907	M
33560	0	Oscar	Bonfiglio	5	10	1905	M
94135	0	Juan	Carreño	14	8	1907	M
33321	0	Jesús	Castro	1	1	1900	M
43777	0	Rafael	Garza Gutiérrez	13	12	1896	M
41910	0	Francisco	Garza Gutiérrez	14	3	1904	M
31066	0	Roberto	Gayón	1	1	1905	M
84297	0	Hilario	López	18	11	1907	M
21313	0	Dionisio	Mejía	6	1	1907	M
27734	0	Felipe	Olivares	18	11	1907	M
31687	0	Luis	Pérez	1	1	1907	M
58196	0	Raymundo	Rodríguez	15	4	1905	M
8566	0	Felipe	Rosas	5	2	1910	M
89481	0	Manuel	Rosas	17	4	1912	M
17565	0	José	Ruíz	1	1	1904	M
83291	0	Alfredo Viejo	Sánchez	24	5	1908	M
65099	0	Isidoro	Sota	4	2	1902	M
33814	0	Francisco	Aguirre	\N	\N	\N	M
35834	0	Pedro	Benítez	12	1	1901	M
30741	0	Santiago	Benítez	\N	\N	\N	M
78377	0	Delfín	Benítez Cáceres	24	9	1910	M
61392	0	Saguier	Carreras	\N	\N	\N	M
51301	0	Eustacio	Chamorro	\N	\N	\N	M
68567	0	Modesto	Denis	\N	\N	\N	M
37309	0	Eusebio	Díaz	\N	\N	\N	M
21707	0	Diógenes	Domínguez	\N	\N	\N	M
8814	0	Romildo	Etcheverry	\N	\N	\N	M
54557	0	Diego	Florentín	\N	\N	\N	M
86082	0	Salvador	Flores	\N	\N	\N	M
65504	0	Tranquilino	Garcete	\N	\N	\N	M
64697	0	Aurelio	González	25	9	1905	M
4623	0	José	Miracca	23	9	1903	M
98075	0	Lino	Nessi	\N	\N	\N	M
11035	0	Quiterio	Olmedo	21	12	1907	M
9057	0	Amadeo	Ortega	\N	\N	\N	M
4417	0	Bernabé	Rivera	\N	\N	\N	M
51624	0	Gerardo	Romero	\N	\N	\N	M
6201	0	Luis	Vargas Peña	23	4	1907	M
51390	0	Jacinto	Villalba	\N	\N	\N	M
35875	0	Eduardo	Astengo	15	8	1905	M
45407	0	Carlos	Cillóniz	1	7	1910	M
79515	0	Mario	de las Casas	31	1	1901	M
7526	0	Alberto	Denegri	7	8	1906	M
45649	0	Arturo	Fernández	10	4	1910	M
64036	0	Plácido	Galindo	9	3	1906	M
38495	0	Domingo	García	\N	\N	\N	M
29687	0	Jorge	Góngora	12	10	1906	M
93477	0	José María	Lavalle	5	6	1911	M
44526	0	Julio	Lores	15	9	1908	M
57115	0	Antonio	Maquilón	29	11	1902	M
71799	0	Demetrio	Neyra	15	12	1908	M
19170	0	Pablo	Pacheco	\N	\N	\N	M
6866	0	Jorge	Pardon	19	12	1909	M
8526	0	Julio	Quintana	13	7	1904	M
27561	0	Lizardo	Rodríguez Nue	30	8	1910	M
36167	0	Jorge	Sarmiento	2	11	1900	M
66691	0	Alberto	Soria	10	3	1906	M
44010	0	Luis	Souza Ferreira	30	6	1904	M
89076	0	Juan	Valdivieso	6	5	1910	M
41536	0	Juan Alfonso	Valle	\N	\N	\N	M
36243	0	Alejandro	Villanueva	4	6	1908	M
99417	0	Ştefan	Barbu	2	3	1908	M
62376	0	Rudolf	Bürger	31	10	1908	M
27752	0	Iosif	Czako	11	6	1906	M
91295	0	Adalbert	Deşu	24	3	1909	M
20672	0	Alfred	Eisenbeisser	7	4	1908	M
70294	0	Miklós	Kovács	23	12	1911	M
9282	0	Ion	Lǎpuşneanu	8	12	1908	M
7972	0	László	Raffinsky	23	4	1905	M
2455	0	Corneliu	Robe	23	5	1908	M
18615	0	Constantin	Stanciu	5	3	1911	M
51872	0	Adalbert	Steiner	24	1	1907	M
81554	0	Ilie	Subăşeanu	1	1	1906	M
22907	0	Emerich	Vogl	12	8	1905	M
85622	0	Rudolf	Wetzer	17	3	1901	M
22304	0	Samuel	Zauber	10	11	1900	M
58795	0	Andy	Auld	26	1	1900	M
94425	0	Mike	Bookie	12	9	1904	M
6424	0	Jim	Brown	31	12	1908	M
12437	0	Jimmy	Douglas	12	1	1898	M
37361	0	Tom	Florie	6	9	1897	M
99522	0	Jimmy	Gallagher	7	6	1901	M
733	0	James	Gentle	21	7	1904	M
85569	0	Billy	Gonsalves	10	8	1908	M
65185	0	Bart	McGhee	30	4	1899	M
25155	0	George	Moorhouse	4	5	1901	M
46121	0	Arnie	Oliver	22	5	1907	M
71973	0	Bert	Patenaude	4	11	1909	M
47437	0	Philip	Slone	20	1	1907	M
4110	0	Raphael	Tracey	6	2	1904	M
49855	0	Frank	Vaughn	18	2	1902	M
56459	0	Alexander	Wood	12	6	1907	M
63826	0	José Leandro	Andrade	22	11	1901	M
57352	0	Peregrino	Anselmo	30	4	1902	M
63987	0	Enrique	Ballesteros	18	1	1905	M
47453	0	Juan Carlos	Calvo	26	6	1906	M
76186	0	Miguel	Capuccini	5	1	1904	M
54697	0	Héctor	Castro	29	11	1904	M
18628	0	Pedro	Cea	1	9	1900	M
38674	0	Pablo	Dorado	22	6	1908	M
53856	0	Lorenzo	Fernández	20	5	1900	M
39785	0	Álvaro	Gestido	17	5	1907	M
31959	0	Santos	Iriarte	2	11	1902	M
49150	0	Ernesto	Mascheroni	21	11	1907	M
55304	0	Ángel	Melogno	22	3	1905	M
76270	0	José	Nasazzi	24	5	1901	M
93278	0	Pedro	Petrone	11	5	1905	M
41238	0	Conduelo	Píriz	17	6	1905	M
63026	0	Emilio	Recoba	3	11	1904	M
98216	0	Carlos	Riolfo	5	11	1905	M
93344	0	Zoilo	Saldombide	18	3	1905	M
44201	0	Héctor	Scarone	26	11	1898	M
86932	0	Domingo	Tejera	27	7	1899	M
17569	0	Santos	Urdinarán	30	3	1900	M
72808	0	Milorad	Arsenijević	6	6	1906	M
43734	0	Ivan	Bek	29	10	1909	M
13261	0	Momčilo	Đokić	27	2	1911	M
15059	0	Branislav	Hrnjiček	5	6	1908	M
44887	0	Milutin	Ivković	3	3	1906	M
24808	0	Milovan	Jakšić	21	9	1909	M
75929	0	Blagoje	Marjanović	9	9	1907	M
10671	0	Bozidar	Marković	1	1	1900	M
19712	0	Dragoslav	Mihajlović	13	12	1906	M
91900	0	Dragutin	Najdanović	15	4	1908	M
94965	0	Branislav	Sekulić	29	10	1906	M
74878	0	Teofilo	Spasojević	21	1	1909	M
62267	0	Ljubiša	Stefanović	4	1	1910	M
55273	0	Milan	Stojanović	28	12	1911	M
43349	0	Aleksandar	Tirnanić	15	7	1911	M
59061	0	Dragomir	Tošić	8	11	1909	M
33565	0	Đorđe	Vujadinović	6	12	1909	M
32516	0	Ernesto	Albarracín	25	9	1907	M
42498	0	Ramón	Astudillo	\N	\N	\N	M
11019	0	Ernesto	Belis	1	2	1909	M
21951	0	Enrique	Chimento	\N	\N	\N	M
5185	0	Alfredo	Devincenzi	24	1	1911	M
98837	0	Héctor	Freschi	22	5	1911	M
61839	0	Alberto	Galateo	4	3	1912	M
33940	0	Ángel	Grippa	2	3	1914	M
82803	0	Roberto	Irañeta	21	3	1915	M
2358	0	Luis	Izzeta	\N	\N	\N	M
32246	0	Arcadio	López	15	9	1910	M
5772	0	Alfonso	Lorenzo	\N	\N	\N	M
64351	0	José	Nehin	13	10	1905	M
15166	0	Juan	Pedevilla	6	6	1909	M
16377	0	Francisco	Pérez	\N	\N	\N	M
94114	0	Francisco	Rúa	4	2	1911	M
33461	0	Constantino	Urbieta Sosa	12	8	1907	M
95620	0	Federico	Wilde	\N	\N	\N	M
51668	0	Josef	Bican	25	9	1913	M
37758	0	Georg	Braun	22	2	1907	M
72888	0	Franz	Cisar	28	11	1908	M
28322	0	Friederich	Franzl	6	3	1905	M
32150	0	Josef	Hassmann	21	5	1910	M
94617	0	Leopold	Hofmann	31	10	1905	M
51711	0	Johann	Horvath	20	5	1903	M
92579	0	Anton	Janda	1	5	1904	M
48419	0	Matthias	Kaburek	9	2	1911	M
14775	0	Peter	Platzer	29	5	1910	M
17740	0	Rudolf	Raftl	7	2	1911	M
87474	0	Anton	Schall	22	6	1907	M
14790	0	Willibald	Schmaus	16	6	1911	M
5609	0	Karl	Sesta	18	3	1906	M
11865	0	Matthias	Sindelar	10	2	1903	M
71630	0	Josef	Smistik	28	11	1905	M
30750	0	Josef	Stroh	5	3	1913	M
97102	0	Johann	Urbanek	10	10	1910	M
65339	0	Rudolf	Viertl	12	11	1902	M
39159	0	Franz	Wagner	23	9	1911	M
19490	0	Hans	Walzhofer	23	3	1906	M
5719	0	Karl	Zischek	28	8	1910	M
57945	0	Désiré	Bourgeois	13	12	1908	M
56476	0	Jean	Brichaut	29	7	1911	M
27187	0	Jean	Capelle	26	10	1913	M
89966	0	Jean	Claessens	18	6	1908	M
31088	0	François	Devries	21	8	1913	M
28338	0	Laurent	Grimmonprez	14	12	1902	M
97896	0	Albert	Heremans	13	4	1906	M
356	0	Constant	Joacim	3	3	1908	M
3817	0	Robert	Lamoot	18	3	1911	M
93825	0	François	Ledent	4	7	1908	M
51930	0	Jules	Pappaert	5	11	1905	M
11200	0	Frans	Peeraer	15	2	1913	M
81829	0	Victor	Putmans	29	5	1914	M
87214	0	René	Simons	10	4	1904	M
38767	0	Philibert	Smellinckx	17	1	1911	M
97759	0	Joseph	Van Ingelgem	23	1	1912	M
32287	0	André	Vandewyer	21	6	1909	M
1972	0	Félix	Welkenhuysen	12	12	1908	M
63886	0	not applicable	Almeida	2	12	1910	M
32881	0	not applicable	Ariel	22	2	1910	M
91413	0	not applicable	Armandinho	6	3	1911	M
7398	0	not applicable	Áttila	16	12	1910	M
3130	0	not applicable	Canalli	12	3	1907	M
52951	0	Waldemar	de Brito	17	5	1913	M
48079	0	not applicable	Germano	14	3	1911	M
93712	0	Sylvio	Hoffmann	15	5	1908	M
9730	0	not applicable	Leônidas	6	9	1913	M
35048	0	not applicable	Luisinho	29	3	1911	M
66864	0	Luiz	Luz	29	11	1909	M
70690	0	not applicable	Martim	2	3	1911	M
77114	0	not applicable	Octacílio	21	11	1909	M
85795	0	not applicable	Patesko	12	11	1910	M
8627	0	not applicable	Pedrosa	8	7	1913	M
3576	0	not applicable	Tinoco	2	12	1904	M
93990	0	not applicable	Waldyr	21	3	1912	M
94788	0	Jaroslav	Bouček	13	11	1912	M
76056	0	Jaroslav	Burgr	7	3	1906	M
28531	0	Štefan	Čambal	17	12	1908	M
68716	0	Josef	Čtyřoký	30	9	1906	M
70254	0	Ferdinand	Daučík	30	5	1910	M
19582	0	František	Junek	17	1	1907	M
88929	0	Géza	Kalocsay	30	5	1913	M
64425	0	Vlastimil	Kopecký	14	10	1912	M
53978	0	Josef	Košťálek	31	8	1909	M
30773	0	Rudolf	Krčil	5	3	1906	M
60513	0	Oldřich	Nejedlý	26	12	1909	M
70970	0	Čestmír	Patzel	2	12	1914	M
52528	0	František	Plánička	2	6	1904	M
51219	0	Antonín	Puč	16	5	1907	M
23820	0	Josef	Silný	23	1	1902	M
94005	0	Adolf	Šimperský	5	8	1909	M
58983	0	Jiří	Sobotka	6	6	1911	M
57162	0	Erich	Srbek	4	6	1908	M
21644	0	František	Šterc	27	1	1912	M
13470	0	František	Svoboda	5	7	1905	M
64843	0	Antonín	Vodička	1	3	1907	M
42431	0	Ladislav	Ženíšek	7	3	1904	M
87740	0	Mohammed	Bakhati	\N	\N	\N	M
78354	0	Hassan	El-Far	1	1	1913	M
62813	0	Ali	El-Kaf	15	6	1906	M
76014	0	Mahmoud	El-Nigero	\N	\N	\N	M
96407	0	Yacout	El-Soury	\N	\N	\N	M
82850	0	Aziz	Fahmy	\N	\N	\N	M
28239	0	Abdulrahman	Fawzi	11	8	1909	M
44834	0	Ahmed	Halim Ibrahim	10	2	1910	M
18819	0	not applicable	Hamidu	\N	\N	\N	M
66692	0	Mohammed	Hassan	5	2	1905	M
55444	0	Hafez	Kasseb	\N	\N	\N	M
45036	0	Mohamed	Latif	23	10	1909	M
13156	0	Labib	Mahmoud	\N	\N	\N	M
17075	0	Mustafa	Mansour	2	8	1914	M
46343	0	Mahmoud	Mokhtar	23	12	1907	M
12336	0	Kamel	Mosaoud	2	8	1914	M
1246	0	Ismail	Rafaat	1	1	1908	M
48383	0	Hassan	Raghab	1	1	1909	M
96789	0	Mostafa	Taha	23	3	1910	M
67758	0	Moustafa Helmi	Youssef	11	6	1911	M
9225	0	Joseph	Alcazar	15	6	1911	M
93801	0	Alfred	Aston	16	5	1912	M
45731	0	Georges	Beaucourt	15	4	1912	M
52655	0	Roger	Courtois	30	5	1912	M
36153	0	Robert	Défossé	16	6	1909	M
30130	0	Louis	Gabrillargues	16	6	1914	M
84475	0	Joseph	Gonzales	19	2	1907	M
26041	0	Fritz	Keller	21	8	1913	M
45865	0	Pierre	Korb	20	4	1908	M
26292	0	Noël	Liétaer	17	11	1908	M
59589	0	René	Llense	14	7	1913	M
69033	0	Jacques	Mairesse	27	2	1905	M
70804	0	Jean	Nicolas	9	6	1913	M
49701	0	Roger	Rio	13	2	1913	M
46249	0	Jules	Vandooren	30	12	1908	M
13166	0	Georges	Verriest	15	7	1909	M
82536	0	Ernst	Albrecht	12	11	1907	M
54695	0	Jakob	Bender	23	3	1910	M
81440	0	Fritz	Buchloh	26	11	1909	M
27770	0	Willy	Busch	4	1	1907	M
77348	0	Edmund	Conen	10	11	1914	M
74210	0	Franz	Dienert	1	1	1900	M
27139	0	Rudolf	Gramlich	6	6	1908	M
69645	0	Sigmund	Haringer	9	12	1908	M
99592	0	Matthias	Heidemann	7	2	1912	M
56231	0	Karl	Hohmann	18	6	1908	M
90001	0	Hans	Jakob	16	6	1908	M
24404	0	Paul	Janes	10	3	1912	M
4241	0	Stanislaus	Kobierski	15	11	1910	M
74349	0	Willibald	Kreß	13	11	1906	M
38753	0	Ernst	Lehner	7	11	1912	M
60828	0	Reinhold	Münzenberg	25	1	1909	M
30818	0	Rudolf	Noack	20	3	1913	M
72423	0	Hans	Schwartz	1	3	1913	M
53238	0	Otto	Siffling	3	8	1912	M
92333	0	Josef	Streb	16	4	1912	M
86518	0	Fritz	Szepan	2	9	1907	M
85695	0	Paul	Zielinski	20	11	1911	M
18927	0	István	Avar	30	5	1905	M
81185	0	Sándor	Bíró	19	8	1911	M
31849	0	János	Dudás	13	2	1911	M
26210	0	Gyula	Futó	29	12	1908	M
70689	0	József	Háda	2	3	1911	M
81445	0	Tibor	Kemény	5	3	1913	M
54489	0	Gyula	Lázár	24	1	1911	M
23517	0	Imre	Markos	9	6	1908	M
32085	0	István	Palotás	5	3	1908	M
10473	0	Gyula	Polgár	8	2	1912	M
89034	0	György	Sárosi	15	9	1912	M
9142	0	Rezső	Somlai	22	5	1911	M
14531	0	László	Sternberg	28	5	1905	M
60980	0	Antal	Szabó	4	9	1910	M
29081	0	Gábor	Szabó	14	10	1902	M
99214	0	Antal	Szalay	12	3	1912	M
37684	0	György	Szűcs	23	4	1912	M
38660	0	István	Tamássy	30	6	1906	M
42669	0	Pál	Teleki	5	3	1906	M
60977	0	Géza	Toldi	11	2	1909	M
91259	0	József	Vágó	30	6	1906	M
11520	0	Jenő	Vincze	20	11	1908	M
22402	0	Luigi	Allemandi	18	11	1903	M
80654	0	Pietro	Arcari	2	12	1909	M
60679	0	Luigi	Bertolini	13	9	1904	M
40103	0	Felice	Borel	5	4	1914	M
84232	0	Umberto	Caligaris	26	7	1901	M
56674	0	Armando	Castellazzi	7	10	1904	M
77995	0	Giuseppe	Cavanna	18	9	1905	M
57546	0	Gianpiero	Combi	20	11	1902	M
39512	0	Giovanni	Ferrari	6	12	1907	M
76282	0	Attilio	Ferraris	26	3	1904	M
3545	0	Enrique	Guaita	11	7	1910	M
16965	0	Anfilogino	Guarisi	26	12	1905	M
93906	0	Guido	Masetti	22	11	1907	M
34536	0	Giuseppe	Meazza	23	8	1910	M
58691	0	Eraldo	Monzeglio	5	6	1906	M
3638	0	Raimundo	Orsi	2	12	1901	M
10605	0	Mario	Pizziolo	7	12	1909	M
30373	0	Virginio	Rosetta	25	2	1902	M
56703	0	Angelo	Schiavio	15	10	1905	M
95210	0	Mario	Varglien	26	12	1905	M
51120	0	Wim	Anderiesen	27	11	1903	M
74001	0	Beb	Bakhuys	16	4	1909	M
69466	0	Jan	Graafland	21	8	1909	M
8052	0	Leo	Halle	17	2	1903	M
84091	0	Wim	Langendaal	13	4	1909	M
81649	0	Kees	Mijnders	28	9	1912	M
75398	0	Jaap	Mol	3	2	1912	M
19181	0	Toon	Oprinsen	25	11	1910	M
67910	0	Bas	Paauwe	4	10	1911	M
19627	0	Henk	Pellikaan	10	11	1910	M
86401	0	Arend	Schoemaker	8	11	1911	M
85884	0	Kick	Smit	3	11	1911	M
28465	0	Gejus	van der Meulen	23	1	1903	M
84890	0	Jan	van Diepenbeek	5	8	1903	M
44776	0	Puck	van Heel	21	1	1904	M
24944	0	Adri	van Male	7	10	1910	M
29803	0	Joop	van Nellen	15	3	1910	M
20598	0	Sjef	van Run	12	1	1904	M
55392	0	Leen	Vente	14	5	1911	M
84101	0	Manus	Vrauwdeunt	29	4	1915	M
83478	0	Mauk	Weber	1	3	1914	M
57256	0	Frank	Wels	21	2	1909	M
76189	0	Gheorghe	Albu	12	9	1909	M
58656	0	Iuliu	Baratky	14	5	1910	M
28958	0	Silviu	Bindea	24	10	1912	M
92768	0	Iuliu	Bodola	26	2	1912	M
83778	0	Gheorghe	Ciolac	10	8	1908	M
55859	0	Alexandru	Cuedan	26	9	1910	M
29524	0	Vasile	Deheleanu	12	8	1910	M
55855	0	Ștefan	Dobay	26	9	1909	M
49480	0	Gusztáv	Juhász	19	12	1911	M
77815	0	István	Klimek	15	4	1913	M
41753	0	Stanislau	Konrad	23	10	1913	M
36734	0	Rudolf	Kotormány	23	1	1911	M
70432	0	Nicolae	Kovács	29	12	1911	M
38049	0	József	Moravetz	14	1	1911	M
67464	0	Adalbert	Püllöck	6	4	1907	M
57363	0	Sándor	Schwartz	18	1	1909	M
89198	0	Grațian	Sepi	30	12	1910	M
49773	0	Lazăr	Sfera	29	4	1909	M
79776	0	Károly	Weichelt	2	3	1906	M
70088	0	Vilmos	Zombori	11	1	1906	M
47714	0	Crisant	Bosch	26	12	1907	M
67537	0	not applicable	Chacho	14	4	1911	M
91286	0	Leonardo	Cilaurren	5	11	1912	M
29275	0	not applicable	Ciriaco	8	8	1904	M
85952	0	not applicable	Fede	14	10	1912	M
54892	0	Guillermo	Gorostiza	15	2	1909	M
89086	0	not applicable	Hilario	8	12	1905	M
17824	0	Campanal	I	9	2	1912	M
64059	0	José	Iraragorri	16	3	1912	M
12120	0	not applicable	Lafuente	31	12	1907	M
69133	0	Isidro	Lángara	25	5	1912	M
3613	0	Simón	Lecue	11	2	1912	M
41247	0	Martín	Marculeta	24	9	1907	M
53344	0	Luis	Marín Sabater	4	9	1906	M
90409	0	José	Muguerza	15	9	1911	M
47982	0	Juan José	Nogués	28	3	1909	M
87531	0	Jacinto	Quincoces	17	7	1905	M
40752	0	Luis	Regueiro	1	7	1908	M
14976	0	Pedro	Solé	7	5	1905	M
17732	0	Martí	Ventolrà	16	12	1906	M
63912	0	Ramón	Zabalo	10	6	1910	M
7867	0	Ricardo	Zamora	21	1	1901	M
23401	0	Ernst	Andersson	26	3	1909	M
45925	0	Otto	Andersson	7	5	1910	M
22714	0	Sven	Andersson	14	2	1907	M
65347	0	Nils	Axelsson	18	1	1906	M
12745	0	Lennart	Bunke	3	4	1912	M
62095	0	Rune	Carlsson	1	10	1909	M
19096	0	Victor	Carlund	5	2	1906	M
83366	0	Gösta	Dunker	16	9	1905	M
92190	0	Erik	Granath	\N	\N	\N	M
66504	0	Ragnar	Gustavsson	28	9	1907	M
22732	0	Carl-Erik	Holmberg	17	7	1906	M
90839	0	Sture	Hult	19	10	1910	M
96043	0	Gunnar	Jansson	17	7	1907	M
1918	0	Carl	Johnsson	\N	\N	\N	M
79374	0	Sven	Jonasson	9	7	1909	M
94204	0	Tore	Keller	4	1	1905	M
2091	0	Knut	Kroon	19	6	1906	M
18347	0	Harry	Lundahl	16	10	1905	M
67034	0	Gunnar	Olsson	19	7	1908	M
16727	0	Nils	Rosén	22	5	1902	M
19469	0	Anders	Rydberg	3	3	1903	M
9085	0	Arvid	Thörn	29	10	1906	M
76001	0	Eivar	Widlund	15	6	1905	M
85334	0	André	Abegglen	7	3	1909	M
64427	0	Renato	Bizzozero	7	9	1912	M
6791	0	Joseph	Bossi	29	8	1911	M
21616	0	Albert	Büche	\N	\N	\N	M
94058	0	Otto	Bühler	\N	\N	\N	M
61867	0	Ernst	Frick	\N	\N	\N	M
53059	0	Louis	Gobet	28	10	1908	M
49691	0	Albert	Guinchard	10	11	1914	M
41260	0	Erwin	Hochsträsser	\N	\N	\N	M
49305	0	Willy	Huber	17	12	1913	M
97291	0	Ernst	Hufschmid	4	2	1913	M
87405	0	Fernand	Jaccard	8	10	1907	M
31231	0	Alfred	Jäck	2	8	1911	M
58205	0	Willy	Jäggi	28	7	1906	M
88416	0	Leopold	Kielholz	9	6	1911	M
35043	0	Edmond	Loichot	\N	\N	\N	M
85276	0	Severino	Minelli	6	9	1909	M
17489	0	Arnaldo	Ortelli	5	8	1913	M
15994	0	Raymond	Passello	12	1	1905	M
96627	0	Frank	Séchehaye	3	11	1907	M
71546	0	Willy	von Känel	30	10	1909	M
13267	0	Walter	Weiler	4	12	1903	M
44740	0	Max	Weiler	25	9	1900	M
37867	0	Tom	Amrhein	\N	\N	\N	M
64188	0	Ed	Czerkiewicz	8	7	1912	M
31804	0	Walter	Dick	20	9	1905	M
75829	0	Aldo	Donelli	22	7	1907	M
65285	0	Bill	Fiedler	10	1	1910	M
51225	0	Al	Harker	11	4	1910	M
64948	0	Julius	Hjulian	15	3	1903	M
71808	0	William	Lehman	20	12	1901	M
65974	0	Tom	Lynch	\N	\N	\N	M
74221	0	Joe	Martinelli	22	8	1916	M
16062	0	Willie	McLean	27	1	1904	M
17263	0	Werner	Nilsen	24	2	1904	M
64536	0	Peter	Pietras	21	4	1908	M
57295	0	Herman	Rapp	\N	\N	\N	M
91378	0	Francis	Ryan	10	1	1908	M
63553	0	Robert	Braet	11	2	1912	M
84927	0	Raymond	Braine	28	4	1907	M
33714	0	Fernand	Buyle	3	3	1918	M
17309	0	Arthur	Ceuleers	28	2	1916	M
73403	0	Pierre	Dalem	16	3	1912	M
94481	0	Alfons	De Winter	12	9	1908	M
44080	0	Jean	Fievez	30	11	1910	M
24202	0	Frans	Gommers	5	4	1917	M
44854	0	Paul	Henry	6	9	1912	M
3499	0	Hendrik	Isemborghs	30	1	1914	M
11957	0	Joseph	Nelis	1	4	1917	M
46631	0	Robert	Paverick	29	11	1912	M
69703	0	Jean	Petit	25	2	1914	M
95279	0	Corneel	Seys	12	2	1912	M
6477	0	Émile	Stijnen	2	11	1907	M
57062	0	John	Van Alphen	17	6	1914	M
32038	0	Charles	Vanden Wouwer	7	9	1916	M
279	0	not applicable	Afonsinho	8	3	1914	M
41619	0	not applicable	Argemiro	3	6	1915	M
14044	0	not applicable	Batatais	20	5	1910	M
24911	0	not applicable	Brandão	21	4	1911	M
14381	0	not applicable	Britto	6	5	1914	M
56060	0	Domingos	da Guia	19	11	1912	M
77661	0	not applicable	Hércules	2	7	1912	M
92554	0	not applicable	Jaú	7	12	1909	M
14047	0	not applicable	Lopes	1	11	1910	M
16663	0	not applicable	Machado	1	1	1909	M
35561	0	not applicable	Martim	21	4	1911	M
68604	0	not applicable	Nariz	8	12	1912	M
88147	0	not applicable	Niginho	12	2	1912	M
70927	0	not applicable	Perácio	2	11	1917	M
81322	0	not applicable	Roberto	20	6	1912	M
44339	0	not applicable	Romeu	26	3	1911	M
5159	0	not applicable	Tim	20	2	1915	M
76392	0	not applicable	Walter	17	7	1912	M
42205	0	not applicable	Zezé Procópio	12	8	1913	M
23003	0	Juan	Alonzo	24	6	1911	M
91946	0	Joaquín	Arias	12	11	1914	M
90611	0	Juan	Ayra	23	6	1911	M
50445	0	Jacinto	Barquín	3	9	1915	M
29608	0	Pedro	Bergés	\N	\N	\N	M
72041	0	Benito	Carvajales	25	7	1913	M
82026	0	Manuel	Chorens	22	1	1916	M
77302	0	Tomás	Fernández	\N	\N	\N	M
46059	0	Pedro	Ferrer	\N	\N	\N	M
56223	0	José	Magriñá	14	12	1917	M
43737	0	Carlos	Oliveira	\N	\N	\N	M
19947	0	José Antonio	Rodríguez	\N	\N	\N	M
77922	0	Héctor	Socorro	26	6	1912	M
47473	0	Mario	Sosa	\N	\N	\N	M
99758	0	Juan	Tuñas	17	7	1917	M
83399	0	Vojtěch	Bradáč	6	10	1913	M
91890	0	Karel	Burkert	1	12	1909	M
48049	0	Karel	Černý	1	2	1910	M
41835	0	Václav	Horák	27	9	1912	M
24836	0	Karel	Kolský	21	9	1914	M
55632	0	Arnošt	Kreuz	9	5	1912	M
29652	0	Josef	Ludl	3	6	1916	M
38048	0	Otakar	Nožíř	12	3	1917	M
33048	0	Josef	Orth	20	5	1916	M
30507	0	Jan	Říha	11	11	1915	M
3127	0	Oldřich	Rulc	28	3	1911	M
47402	0	Karel	Senecký	17	3	1919	M
15892	0	Ladislav	Šimůnek	4	10	1916	M
27945	0	Josef	Zeman	23	1	1915	M
65883	0	Sutan	Anwar	21	3	1914	M
16278	0	not applicable	Dorst	\N	\N	\N	M
51934	0	Gerrit	Faulhaber	22	9	1912	M
72195	0	Jan	Harting	\N	\N	\N	M
56198	0	Frans	Hu Kon	\N	\N	\N	M
38291	0	Frans Alfred	Meeng	18	1	1910	M
5443	0	Achmad	Nawir	1	1	1911	M
8131	0	Isaak	Pattiwael	23	2	1914	M
3631	0	Jack	Samuels	\N	\N	\N	M
59945	0	Suvarte	Soedarmadji	6	12	1915	M
19995	0	Hans	Taihuttu	\N	\N	\N	M
52233	0	Mo Heng	Tan	28	2	1913	M
89666	0	See Han	Tan	\N	\N	\N	M
92120	0	not applicable	Teilherber	\N	\N	\N	M
3175	0	Rudi	Telwe	\N	\N	\N	M
69801	0	Hong Djien	The	12	1	1916	M
37048	0	Leen	van Beuzekom	\N	\N	\N	M
38536	0	not applicable	Van Den Burgh	\N	\N	\N	M
67536	0	Hendrikus	Zomers	\N	\N	\N	M
69619	0	Jean	Bastien	21	6	1915	M
9795	0	Abdelkader	Ben Bouali	25	10	1912	M
79828	0	François	Bourbotte	24	2	1913	M
50527	0	Michel	Brusseaux	19	3	1913	M
92301	0	Hector	Cazenave	13	4	1914	M
94763	0	Julien	Darui	16	2	1916	M
65422	0	Laurent	Di Lorto	1	1	1909	M
18863	0	Raoul	Diagne	10	11	1910	M
78235	0	Oscar	Heisserer	18	7	1914	M
38344	0	Lucien	Jasseron	29	12	1913	M
26887	0	Auguste	Jordan	21	2	1909	M
36564	0	Ignace	Kowalczyk	27	12	1913	M
16634	0	Martin	Povolny	19	7	1914	M
70720	0	Mario	Zatelli	21	12	1912	M
15763	0	Josef	Gauchel	11	9	1916	M
25957	0	Rudolf	Gellesch	1	5	1914	M
71483	0	Ludwig	Goldbrunner	5	3	1908	M
53466	0	Wilhelm	Hahnemann	14	4	1914	M
21402	0	Albin	Kitzinger	1	2	1912	M
82099	0	Andreas	Kupfer	7	5	1914	M
281	0	Hans	Mock	9	12	1906	M
47513	0	Leopold	Neumer	8	2	1919	M
46036	0	Hans	Pesser	7	11	1911	M
58969	0	Stefan	Skoumal	29	11	1909	M
43378	0	Jakob	Streitle	11	12	1916	M
58088	0	István	Balogh	21	9	1912	M
1726	0	Mihály	Bíró	20	7	1914	M
4962	0	László	Cseh	4	4	1910	M
53740	0	Vilmos	Kohut	17	7	1906	M
25927	0	Lajos	Korányi	15	5	1907	M
36957	0	József	Pálinkás	10	3	1912	M
52028	0	Béla	Sárosi	15	5	1919	M
37357	0	Ferenc	Sas	15	3	1915	M
24305	0	Pál	Titkos	8	1	1908	M
33184	0	József	Turay	1	3	1905	M
67652	0	Gyula	Zsengellér	27	12	1915	M
79580	0	Michele	Andreolo	6	9	1912	M
62660	0	Sergio	Bertoni	23	9	1915	M
85283	0	Amedeo	Biavati	4	4	1915	M
94715	0	Carlo	Ceresoli	14	5	1910	M
9916	0	Bruno	Chizzo	19	4	1916	M
76066	0	Gino	Colaussi	4	3	1914	M
7254	0	Aldo	Donati	29	9	1910	M
58640	0	Pietro	Ferraris	15	2	1912	M
97762	0	Alfredo	Foni	20	11	1911	M
7131	0	Mario	Genta	1	3	1912	M
79327	0	Ugo	Locatelli	5	2	1916	M
95291	0	Aldo	Olivieri	2	10	1910	M
98926	0	Renato	Olmi	12	7	1914	M
30716	0	Piero	Pasinati	21	7	1910	M
74793	0	Mario	Perazzolo	7	6	1911	M
65885	0	Silvio	Piola	29	9	1913	M
27048	0	Pietro	Rava	21	1	1916	M
82806	0	Pietro	Serantoni	11	12	1906	M
1561	0	Dick	Been	2	7	1909	M
92370	0	Bertus	Caldenhove	19	1	1914	M
61401	0	Piet	de Boer	10	10	1919	M
27345	0	Bertus	de Harder	14	1	1920	M
92587	0	Arie	de Winter	27	10	1913	M
22639	0	Daaf	Drok	23	5	1914	M
21727	0	Frans	Hogenbirk	18	3	1919	M
39735	0	Niek	Michel	30	9	1912	M
71910	0	Klaas	Ooms	9	6	1916	M
29879	0	Rene	Pijpers	15	9	1917	M
60379	0	Hendrikus	Plenter	23	6	1913	M
61772	0	Piet	Punt	6	2	1909	M
21967	0	Frans	van der Veen	25	3	1918	M
91177	0	Henk	van Spaandonck	25	6	1913	M
39938	0	Roald	Amundsen	18	9	1913	M
44129	0	Oddmund	Andersen	21	12	1915	M
27507	0	Gunnar	Andreassen	5	1	1913	M
17838	0	Hjalmar	Andresen	18	7	1914	M
54406	0	Sverre	Berglie	21	10	1910	M
7024	0	Arne	Brustad	14	4	1912	M
19044	0	Knut	Brynildsen	23	7	1917	M
47235	0	Nils	Eriksen	5	3	1911	M
67971	0	Odd	Frantzen	20	1	1913	M
36967	0	Sigurd	Hansen	23	6	1913	M
60666	0	Kristian	Henriksen	3	3	1911	M
7358	0	Rolf	Holmberg	24	8	1914	M
64492	0	Øivind	Holmsen	28	4	1912	M
32828	0	Arne	Ileby	2	12	1913	M
67226	0	Magnar	Isaksen	13	10	1910	M
49779	0	Rolf	Johannessen	15	3	1910	M
79093	0	Henry	Johansen	21	7	1904	M
6148	0	Jørgen	Juve	22	11	1906	M
51305	0	Anker	Kihle	19	4	1917	M
27380	0	Reidar	Kvammen	23	7	1914	M
24384	0	Alf	Martinsen	29	12	1911	M
52552	0	Sverre	Nordby	13	3	1910	M
1935	0	Stanisław	Baran	26	4	1920	M
96120	0	Walter	Brom	14	2	1921	M
65254	0	Ewald	Cebula	22	3	1917	M
13873	0	Ewald	Dytko	18	10	1914	M
11656	0	Antoni	Gałecki	4	6	1906	M
43303	0	Edmund	Giemsa	16	10	1912	M
99122	0	Wilhelm	Góra	18	1	1916	M
56303	0	Bolesław	Habowski	13	9	1914	M
10030	0	Józef	Korbas	11	11	1914	M
35230	0	Kazimierz	Lis	9	4	1910	M
15302	0	Antoni	Łyko	27	5	1907	M
49430	0	Edward	Madejski	11	8	1914	M
91166	0	Erwin	Nyc	24	5	1914	M
1434	0	Leonard	Piątek	3	10	1913	M
35147	0	Ryszard	Piec	17	8	1913	M
62725	0	Wilhelm	Piec	7	1	1915	M
72075	0	Fryderyk	Scherfke	7	9	1909	M
58047	0	Władysław	Szczepaniak	19	5	1910	M
47738	0	Edmund	Twórz	12	2	1914	M
84687	0	Jan	Wasiewicz	6	1	1911	M
13828	0	Ernst	Wilimowski	23	6	1916	M
29364	0	Gerard	Wodarz	10	8	1913	M
44963	0	Andrei	Bărbulescu	25	3	1917	M
60365	0	Ion	Bogdan	6	3	1915	M
30413	0	Gheorghe	Brandabura	23	2	1913	M
96839	0	Coloman	Braun-Bogdan	13	10	1905	M
4762	0	Vasile	Chiroiu	13	8	1910	M
4835	0	Vintilă	Cossini	21	11	1913	M
28452	0	Mircea	David	16	10	1914	M
38288	0	Iacob	Felecan	1	3	1914	M
79803	0	Ioachim	Moldoveanu	17	8	1913	M
91529	0	Miklós	Nagy	12	1	1918	M
2702	0	Dumitru	Pavlovici	26	4	1912	M
73278	0	Gyula	Prassler	16	1	1916	M
92937	0	Gheorghe	Rășinaru	10	2	1915	M
85689	0	Robert	Sadowski	16	8	1914	M
4266	0	Henock	Abrahamsson	29	10	1909	M
17215	0	Erik	Almgren	28	1	1908	M
99591	0	Åke	Andersson	22	4	1917	M
38092	0	Harry	Andersson	7	3	1913	M
85944	0	Curt	Bergsten	21	8	1915	M
71253	0	Ivar	Eriksson	25	12	1909	M
84346	0	Karl-Erik	Grahn	5	11	1914	M
69313	0	Knut	Hansson	9	5	1911	M
90805	0	Sven	Jacobsson	17	4	1914	M
92191	0	Olle	Källgren	7	9	1907	M
56514	0	Arne	Linderholm	22	2	1916	M
85347	0	Erik	Nilsson	6	8	1916	M
80526	0	Harry	Nilsson	\N	\N	\N	M
97601	0	Arne	Nyberg	20	6	1913	M
13257	0	Erik	Persson	19	11	1909	M
37708	0	Gustav	Sjöberg	23	3	1913	M
740	0	Kurt	Svanström	24	3	1915	M
33341	0	Sven	Unger	\N	\N	\N	M
58852	0	Gustav	Wetterström	15	10	1911	M
80329	0	Georges	Aeby	10	9	1910	M
40938	0	Paul	Aeby	10	9	1910	M
59353	0	Lauro	Amadò	14	3	1912	M
44209	0	Erwin	Ballabio	20	10	1918	M
50918	0	Alfred	Bickel	2	5	1918	M
6111	0	Alessandro	Frigerio	15	11	1914	M
5303	0	Tullio	Grassi	5	2	1910	M
60333	0	August	Lehmann	26	1	1909	M
42031	0	Ernst	Lörtscher	15	3	1913	M
55586	0	Oscar	Rauch	20	3	1914	M
90336	0	Eugen	Rupf	\N	\N	\N	M
52493	0	Hermann	Springer	4	12	1908	M
95497	0	Adolf	Stelzer	1	9	1908	M
34867	0	Sirio	Vernati	12	5	1907	M
22319	0	Fritz	Wagner	\N	\N	\N	M
81006	0	Eugen	Walaschek	20	6	1916	M
1989	0	Alberto	Achá	18	2	1917	M
11079	0	Víctor Celestino	Algarañaz	6	4	1926	M
71503	0	Alberto	Aparicio	11	11	1923	M
15436	0	Duberty	Aráoz	21	12	1920	M
32386	0	Vicente	Arraya	25	1	1921	M
46561	0	Juan	Arricio	11	12	1923	M
44723	0	Víctor	Brown	7	3	1927	M
20091	0	José	Bustamante	5	3	1922	M
67363	0	René	Cabrera	21	10	1925	M
5119	0	Roberto	Capparelli	18	11	1923	M
72370	0	Leonardo	Ferrel	7	7	1923	M
52656	0	Benedicto	Godoy Véizaga	28	7	1924	M
97528	0	Antonio	Greco	17	9	1923	M
69661	0	Juan	Guerra	13	4	1927	M
25954	0	Benigno	Gutiérrez	1	9	1925	M
71481	0	Eduardo	Gutiérrez	17	1	1925	M
27174	0	Benjamin	Maldonado	4	1	1928	M
58955	0	Mario	Mena	28	2	1927	M
11841	0	Humberto	Saavedra	3	8	1923	M
54466	0	Eulogio	Sandoval	22	7	1922	M
97331	0	Víctor Agustín	Ugarte	5	5	1926	M
5024	0	Antonio	Valencia	10	5	1925	M
56943	0	not applicable	Adãozinho	2	4	1923	M
49381	0	not applicable	Ademir	8	11	1922	M
83086	0	not applicable	Alfredo	1	1	1920	M
68961	0	not applicable	Augusto	22	10	1920	M
17754	0	not applicable	Baltazar	14	1	1926	M
54481	0	not applicable	Barbosa	27	3	1921	M
80201	0	not applicable	Bauer	21	11	1925	M
22051	0	not applicable	Bigode	4	4	1922	M
86570	0	Carlos José	Castilho	27	11	1927	M
22428	0	not applicable	Chico	7	1	1922	M
28983	0	not applicable	Danilo	3	12	1920	M
69827	0	not applicable	Ely	14	5	1921	M
21738	0	not applicable	Friaça	20	10	1924	M
44754	0	not applicable	Jair	21	3	1921	M
6730	0	not applicable	Juvenal	27	11	1923	M
99436	0	not applicable	Maneca	28	1	1926	M
59996	0	not applicable	Nena	27	3	1921	M
48847	0	not applicable	Noronha	25	9	1918	M
3310	0	not applicable	Rodrigues	27	6	1925	M
17764	0	not applicable	Rui	2	8	1922	M
75955	0	Nílton	Santos	16	5	1925	M
73743	0	not applicable	Zizinho	14	9	1922	M
9739	0	Manuel	Álvarez Jiménez	23	5	1928	M
56673	0	Miguel	Busquets	15	10	1920	M
16365	0	Fernando	Campos	15	10	1923	M
19583	0	Hernán	Carvallo	19	8	1922	M
86320	0	Atilio	Cremaschi	8	3	1923	M
73717	0	Guillermo	Díaz	29	12	1930	M
22625	0	Arturo	Farías	1	9	1927	M
1719	0	Miguel	Flores	11	10	1920	M
12771	0	Carlos	Ibáñez	28	11	1930	M
45101	0	Raimundo	Infante	2	2	1928	M
59252	0	Sergio	Livingstone	26	3	1920	M
79363	0	Manuel	Machuca	6	6	1924	M
27728	0	Luis	Mayanés	15	1	1925	M
53655	0	Manuel	Muñoz	28	4	1928	M
56453	0	Andrés	Prieto	19	12	1928	M
79097	0	René	Quitral	15	9	1924	M
92243	0	Fernando	Riera	27	6	1920	M
14657	0	George	Robledo	14	4	1926	M
22014	0	Carlos	Rojas	2	10	1928	M
42994	0	Fernando	Roldán	24	7	1930	M
7709	0	Osvaldo	Saez	13	8	1923	M
54152	0	Francisco	Urroz	14	12	1920	M
81597	0	John	Aston	3	9	1921	M
41814	0	Eddie	Baily	6	8	1925	M
64577	0	Roy	Bentley	17	5	1924	M
15889	0	Henry	Cockburn	14	9	1921	M
49092	0	Jimmy	Dickinson	25	4	1925	M
82421	0	Ted	Ditchburn	24	10	1921	M
5485	0	Bill	Eckersley	16	7	1925	M
86813	0	Tom	Finney	5	4	1922	M
7563	0	Laurie	Hughes	2	3	1924	M
71516	0	Wilf	Mannion	16	5	1918	M
51382	0	Stanley	Matthews	1	2	1915	M
8234	0	Jackie	Milburn	11	5	1924	M
89453	0	Stan	Mortensen	26	5	1921	M
82512	0	Jimmy	Mullen	6	1	1923	M
66818	0	Bill	Nicholson	26	1	1919	M
2061	0	Alf	Ramsey	22	1	1920	M
1106	0	Laurie	Scott	23	4	1917	M
79620	0	Jim	Taylor	5	11	1917	M
25248	0	Willie	Watson	7	3	1920	M
14235	0	Bert	Williams	31	1	1920	M
43459	0	Billy	Wright	6	2	1924	M
92780	0	Amedeo	Amadei	26	7	1921	M
36550	0	Carlo	Annovazzi	24	5	1925	M
5462	0	Ivano	Blason	24	5	1923	M
75209	0	Giampiero	Boniperti	4	7	1928	M
62088	0	Aldo	Campatelli	7	4	1919	M
24692	0	Gino	Cappello	2	6	1920	M
36309	0	Emilio	Caprile	30	9	1928	M
51460	0	Riccardo	Carapellese	1	7	1922	M
6741	0	Giuseppe	Casari	10	4	1922	M
23253	0	Osvaldo	Fattori	22	6	1922	M
21916	0	Zeffiro	Furiassi	19	1	1923	M
98659	0	Attilio	Giovannini	30	7	1924	M
45203	0	Benito	Lorenzi	20	12	1925	M
74027	0	Augusto	Magli	9	3	1923	M
7093	0	Giacomo	Mari	17	10	1924	M
73814	0	Giuseppe	Moro	16	1	1921	M
49869	0	Ermes	Muccinelli	28	7	1927	M
152	0	Egisto	Pandolfini	19	2	1926	M
58223	0	Carlo	Parola	20	9	1921	M
1357	0	Leandro	Remondini	17	11	1917	M
59293	0	Lucidio	Sentimenti	1	7	1920	M
42008	0	Omero	Tognon	3	3	1924	M
28840	0	José Luis	Borbolla	31	1	1920	M
69496	0	Antonio	Carbajal	7	6	1929	M
22131	0	Horacio	Casarín	25	5	1918	M
51375	0	Raúl	Córdoba	13	3	1924	M
1521	0	Samuel	Cuburu	20	2	1928	M
52046	0	Antonio	Flores	13	7	1923	M
74225	0	Gregorio	Gómez	26	6	1924	M
25299	0	Carlos	Guevara	\N	\N	\N	M
78559	0	Manuel	Gutiérrez	8	4	1920	M
10564	0	Francisco	Hernández	16	1	1924	M
66344	0	Alfonso	Montemayor	28	4	1922	M
44601	0	José	Naranjo	19	3	1926	M
78973	0	Leonardo	Navarro	\N	\N	\N	M
98520	0	Mario	Ochoa	7	11	1927	M
36858	0	Héctor	Ortiz	20	12	1928	M
49495	0	Mario	Pérez	19	2	1927	M
79398	0	Max	Prieto	28	3	1919	M
92882	0	José Antonio	Roca	24	5	1928	M
83784	0	Rodrigo	Ruiz	14	4	1923	M
65280	0	Carlos	Septién	18	1	1923	M
67199	0	José	Velázquez	12	8	1923	M
55906	0	Felipe	Zetter	3	7	1923	M
92179	0	Enrique	Avalos	\N	\N	\N	M
96339	0	Marcial	Avalos	5	12	1921	M
39480	0	Melanio	Baez	\N	\N	\N	M
76565	0	Ángel	Berni	9	1	1931	M
52495	0	Antonio	Cabrera	\N	\N	\N	M
92623	0	Lorenzo	Calonga	28	8	1929	M
15799	0	Juan	Cañete	27	7	1929	M
69782	0	Castor	Cantero	12	1	1918	M
33494	0	Pablo	Centurión	\N	\N	\N	M
1889	0	Casiano	Céspedes	\N	\N	\N	M
95911	0	César López	Fretes	21	3	1923	M
85737	0	Manuel	Gavilán	30	11	1920	M
1116	0	Alberto	González	\N	\N	\N	M
61383	0	Armando	González	\N	\N	\N	M
40379	0	Darío	Jara Saguier	27	1	1930	M
66341	0	Victoriano	Leguizamón	23	3	1922	M
31665	0	Atilio	López	5	2	1925	M
97223	0	Hilarión	Osorio	21	10	1928	M
2863	0	Elioro	Paredes	19	6	1921	M
70832	0	Francisco	Sosa	\N	\N	\N	M
22122	0	Leongino	Unzaim	16	5	1925	M
52199	0	Marcelino	Vargas	\N	\N	\N	M
79480	0	Juan	Acuña	11	1	1923	M
80682	0	Gabriel	Alonso	9	11	1923	M
49542	0	Francisco	Antúnez	1	11	1922	M
67172	0	Vicente	Asensi	28	1	1919	M
26928	0	Estanislau	Basora	18	11	1926	M
20802	0	not applicable	César	29	6	1920	M
57117	0	Ignacio	Eizaguirre	7	11	1920	M
92865	0	Agustín	Gaínza	28	5	1922	M
48908	0	Josep	Gonzalvo	16	1	1920	M
69140	0	Marià	Gonzalvo	22	3	1922	M
72035	0	Rosendo	Hernández	1	3	1921	M
24336	0	Silvestre	Igoa	5	9	1920	M
28347	0	José	Juncosa	2	2	1922	M
57993	0	Rafael	Lesmes	9	11	1926	M
46247	0	Luis	Molowny	12	5	1925	M
7639	0	not applicable	Nando	1	2	1921	M
23492	0	José Luis	Panizo	12	1	1922	M
33693	0	José	Parra	28	8	1925	M
82311	0	Antonio	Puchades	4	6	1925	M
72288	0	Antoni	Ramallets	4	6	1924	M
25911	0	Alfonso	Silva	19	3	1926	M
65220	0	Telmo	Zarra	20	1	1921	M
38468	0	Olle	Åhlund	22	8	1920	M
91027	0	Sune	Andersson	22	2	1921	M
39881	0	Ingvar	Gärd	6	10	1921	M
3089	0	Hasse	Jeppson	10	5	1925	M
87826	0	Gunnar	Johansson	29	2	1924	M
84831	0	Egon	Jönsson	8	10	1921	M
50231	0	Torsten	Lindberg	14	4	1917	M
29497	0	Arne	Månsson	11	11	1925	M
59295	0	Bror	Mellberg	9	12	1923	M
81653	0	Stellan	Nilsson	28	5	1922	M
39211	0	Knut	Nordahl	13	1	1920	M
52190	0	Karl-Erik	Palmér	17	4	1929	M
79649	0	Kjell	Rosén	24	4	1921	M
87452	0	Ingvar	Rydell	7	5	1922	M
21477	0	Lennart	Samuelsson	7	7	1924	M
33095	0	Lennart	Skoglund	24	12	1929	M
87073	0	Stig	Sundqvist	19	7	1922	M
15746	0	Kalle	Svensson	11	11	1925	M
35817	0	Kurt	Svensson	15	4	1927	M
26019	0	Tore	Svensson	6	12	1927	M
42194	0	Börje	Tapper	20	5	1922	M
98547	0	Charles	Antenen	3	11	1929	M
69750	0	René	Bader	7	8	1922	M
40730	0	Walter	Beerli	23	7	1928	M
27876	0	Roger	Bocquet	9	4	1921	M
57868	0	Eugen	Corrodi	2	7	1922	M
44178	0	Oliver	Eggimann	28	1	1919	M
80623	0	Jacques	Fatton	19	12	1925	M
89785	0	Hans-Peter	Friedländer	6	11	1920	M
1892	0	Rudolf	Gyger	16	4	1920	M
13066	0	Adolphe	Hug	23	9	1923	M
97894	0	Willy	Kernen	6	8	1929	M
93813	0	Gerhard	Lusenti	24	4	1921	M
19543	0	André	Neury	3	9	1921	M
75156	0	Roger	Quinche	22	7	1922	M
67346	0	Kurt	Rey	10	12	1923	M
5710	0	Walter	Schneiter	18	6	1918	M
15697	0	Hans	Siegenthaler	5	2	1923	M
71162	0	Felice	Soldini	26	10	1915	M
89657	0	Willi	Steffen	24	5	1923	M
506	0	Georges	Stuber	11	5	1925	M
15806	0	Jean	Tamini	9	12	1919	M
70389	0	Robert	Annis	5	9	1928	M
43823	0	Walter	Bahr	1	4	1927	M
89288	0	Frank	Borghi	9	4	1925	M
6124	0	Charlie	Colombo	20	7	1920	M
81517	0	Geoff	Coombes	23	4	1919	M
62878	0	Robert	Craddock	5	9	1923	M
26508	0	Nicholas	DiOrio	4	2	1921	M
62622	0	Joe	Gaetjens	19	3	1924	M
85649	0	Gino	Gardassanich	26	11	1922	M
71673	0	Harry	Keough	15	11	1927	M
59276	0	Joe	Maca	28	9	1920	M
46476	0	Ed	McIlvenny	21	10	1924	M
53883	0	Frank	Moniz	26	9	1911	M
88982	0	Gino	Pariani	21	2	1928	M
62843	0	Ed	Souza	22	9	1921	M
81717	0	John	Souza	12	7	1920	M
37569	0	Frank	Wallace	15	7	1922	M
87829	0	Adam	Wolanin	13	11	1919	M
36262	0	Julio César	Britos	18	5	1926	M
14115	0	Juan	Burgueño	4	2	1923	M
85637	0	Schubert	Gambetta	14	4	1920	M
16302	0	Alcides	Ghiggia	22	12	1926	M
85328	0	Juan Carlos	González	22	8	1924	M
54509	0	Matías	González	6	8	1925	M
12327	0	William	Martínez	13	1	1928	M
38439	0	Roque	Máspoli	12	10	1917	M
18523	0	Oscar	Míguez	5	12	1927	M
8534	0	Rubén	Morán	6	8	1930	M
618	0	Washington	Ortuño	13	5	1928	M
64761	0	Aníbal	Paz	21	5	1917	M
84660	0	Julio	Pérez	19	6	1926	M
76749	0	Rodolfo	Pini	12	11	1926	M
54124	0	Luis	Rijo	28	9	1927	M
40941	0	Víctor	Rodríguez Andrade	2	5	1927	M
72726	0	Carlos	Romero	7	9	1927	M
38873	0	Juan Alberto	Schiaffino	28	7	1925	M
44446	0	Eusebio	Tejera	6	1	1922	M
65940	0	Obdulio	Varela	20	9	1917	M
36239	0	Ernesto	Vidal	15	11	1921	M
67013	0	Héctor	Vilches	14	2	1926	M
83771	0	Aleksandar	Atanacković	29	4	1920	M
6291	0	Vladimir	Beara	2	11	1928	M
83431	0	Stjepan	Bobek	3	12	1923	M
11158	0	Božo	Broketa	24	12	1921	M
23914	0	Željko	Čajkovski	5	5	1925	M
39366	0	Zlatko	Čajkovski	24	11	1923	M
69190	0	Ratko	Čolić	17	3	1918	M
82339	0	Predrag	Đajić	1	5	1922	M
78829	0	Vladimir	Firm	5	6	1923	M
78579	0	Ivica	Horvat	16	7	1926	M
54840	0	Miodrag	Jovanović	17	1	1922	M
63357	0	Ervin	Katnić	2	9	1921	M
22353	0	Prvoslav	Mihajlović	13	4	1921	M
50931	0	Rajko	Mitić	19	11	1922	M
37589	0	Srđan	Mrkušić	26	6	1915	M
87730	0	Tihomir	Ognjanov	2	3	1927	M
8770	0	Bela	Palfi	16	2	1923	M
70887	0	Ivo	Radovniković	9	2	1918	M
23555	0	Branko	Stanković	31	10	1921	M
7620	0	Kosta	Tomašević	25	7	1923	M
93505	0	Bernard	Vukas	1	5	1927	M
60319	0	Siniša	Zlatković	28	1	1924	M
69826	1	Kurt	Schmied	14	6	1926	M
98569	2	Gerhard	Hanappi	16	2	1929	M
34192	3	Ernst	Happel	29	11	1925	M
75651	4	Leopold	Barschandt	12	8	1925	M
53882	5	Ernst	Ocwirk	7	3	1926	M
32967	6	Karl	Koller	9	2	1929	M
57242	7	Robert	Körner	21	8	1924	M
28341	8	Walter	Schleger	19	9	1929	M
35865	9	Theodor	Wagner	6	8	1927	M
85257	10	Erich	Probst	5	12	1927	M
26700	11	Alfred	Körner	14	2	1926	M
49790	12	Karl	Stotz	27	3	1927	M
66263	13	Walter	Kollmann	17	6	1932	M
9648	14	Karl	Giesser	29	10	1928	M
16610	15	Franz	Pelikan	6	11	1925	M
93772	16	Walter	Zeman	1	5	1927	M
89866	17	Alfred	Teinitzer	29	7	1929	M
38526	18	Johann	Riegler	17	7	1929	M
80274	19	Robert	Dienst	1	3	1928	M
11040	20	Paul	Halla	10	4	1931	M
51339	21	Ernst	Stojaspal	14	1	1925	M
38037	22	Walter	Haummer	22	11	1928	M
88474	1	Léopold	Gernaey	25	2	1927	M
82650	2	Marcel	Dries	19	9	1929	M
50070	3	Alfons	Van Brandt	24	6	1927	M
93298	4	Constant	Huysmans	11	10	1928	M
34780	5	Louis	Carré	7	1	1925	M
66559	6	Victor	Mees	26	1	1927	M
67742	7	Jozef	Vliers	18	12	1932	M
90085	8	Denis	Houf	16	2	1932	M
26664	9	Henri	Coppens	29	4	1930	M
99158	10	Léopold	Anoul	19	8	1922	M
21144	11	Joseph	Mermans	16	2	1922	M
43724	12	Charles	Geerts	29	10	1930	M
1895	13	Henri	Dirickx	7	7	1927	M
52841	14	Robert	Van Kerkhoven	1	10	1924	M
62692	15	Hippolyte	Van Den Bosch	30	4	1926	M
19279	16	Pieter	Van Den Bosch	31	10	1927	M
88961	17	Raymond	Ausloos	15	5	1928	M
14373	18	Jef	Van Der Linden	2	11	1927	M
2344	19	Jo	Backaert	5	8	1921	M
16358	20	Robert	Maertens	24	1	1930	M
88434	21	Jean	Van Steen	2	6	1929	M
65653	22	Luc	Van Hoyweghen	7	1	1929	M
52002	2	Djalma	Santos	27	2	1929	M
25037	4	not applicable	Brandãozinho	9	6	1925	M
16760	5	not applicable	Pinheiro	13	1	1932	M
8966	7	not applicable	Julinho	29	7	1929	M
76740	8	not applicable	Didi	8	10	1928	M
15387	10	not applicable	Pinga	11	2	1924	M
9512	12	not applicable	Paulinho	15	4	1932	M
93949	13	not applicable	Alfredo	27	10	1924	M
34782	15	Mauro	Ramos	30	8	1930	M
15506	16	not applicable	Dequinha	19	3	1928	M
99918	17	not applicable	Maurinho	6	6	1933	M
4721	18	not applicable	Humberto	4	2	1934	M
38339	19	not applicable	Índio	1	3	1931	M
45852	20	not applicable	Rubens	4	11	1928	M
83158	21	not applicable	Veludo	7	8	1930	M
46849	22	not applicable	Cabeção	23	8	1930	M
98896	1	Theodor	Reimann	10	2	1921	M
93437	2	František	Šafránek	2	1	1931	M
21834	3	Svatopluk	Pluskal	28	10	1930	M
77492	4	Ladislav	Novák	5	12	1931	M
45746	5	Jiří	Trnka	2	12	1926	M
22957	6	Michal	Benedikovič	31	5	1923	M
16096	7	Ladislav	Hlaváček	26	6	1925	M
95256	8	Otto	Hemele	22	1	1926	M
36121	9	Anton	Malatinský	15	1	1920	M
12214	10	Emil	Pažický	14	10	1927	M
19161	11	Jiří	Pešek	4	6	1927	M
47234	12	Anton	Krásnohorský	22	10	1925	M
34931	13	Jiří	Hledík	19	4	1929	M
85922	14	Jan	Hertl	23	1	1929	M
59066	15	Ladislav	Kačáni	1	4	1931	M
44038	16	Zdeněk	Procházka	12	1	1928	M
94749	17	Tadeáš	Kraus	22	10	1932	M
95129	18	Josef	Majer	8	6	1925	M
20189	19	Jaroslav	Košnar	17	8	1930	M
26239	20	Kazimír	Gajdoš	28	3	1934	M
71680	21	Imrich	Stacho	4	11	1931	M
9155	22	Viliam	Schrojf	2	8	1931	M
19646	1	Gil	Merrick	26	1	1922	M
38384	2	Ron	Staniforth	13	4	1924	M
57872	3	Roger	Byrne	8	9	1929	M
8874	5	Syd	Owen	28	2	1922	M
88758	8	Ivor	Broadis	18	12	1922	M
81234	9	Nat	Lofthouse	27	8	1925	M
81755	10	Tommy	Taylor	29	1	1932	M
29849	12	Ted	Burgin	29	4	1927	M
3147	13	Ken	Green	27	4	1924	M
32350	14	Bill	McGarry	10	6	1927	M
25319	15	Dennis	Wilshaw	11	3	1926	M
88110	16	Albert	Quixall	9	8	1933	M
75107	18	Allenby	Chilton	16	9	1918	M
16654	19	Ken	Armstrong	3	6	1924	M
45485	20	Bedford	Jezzard	19	10	1927	M
3578	21	Johnny	Haynes	17	10	1934	M
66723	22	Harry	Hooper	14	6	1933	M
15615	1	François	Remetter	8	8	1928	M
6049	2	César	Ruminski	14	6	1924	M
2042	3	Claude	Abbes	24	5	1927	M
46888	4	Lazare	Gianessi	9	11	1925	M
6319	5	Jacques	Grimonpon	30	7	1925	M
76532	6	Raymond	Kaelbel	31	1	1932	M
77459	7	Roger	Marche	5	3	1924	M
39411	8	Guillaume	Bieganski	3	11	1932	M
38451	9	Antoine	Cuissard	19	7	1924	M
37808	10	Robert	Jonquet	3	5	1925	M
75698	11	Xercès	Louis	31	10	1926	M
47282	12	Jean-Jacques	Marcel	13	6	1931	M
79631	13	Abderrahmane	Mahjoub	25	4	1929	M
66325	14	Armand	Penverne	26	11	1926	M
2848	15	Abdelaziz	Ben Tifour	25	7	1927	M
21077	16	René	Dereuddre	26	6	1930	M
16064	17	Léon	Glovacki	19	2	1928	M
94605	18	Raymond	Kopa	13	10	1931	M
42108	19	Michel	Leblond	10	5	1932	M
10730	20	Ernest	Schultz	29	1	1931	M
53023	21	André	Strappe	23	2	1928	M
78417	22	Jean	Vincent	29	11	1930	M
81262	1	Gyula	Grosics	4	2	1926	M
37134	2	Jenő	Buzánszky	4	5	1925	M
40638	3	Gyula	Lóránt	6	2	1923	M
29493	4	Mihály	Lantos	29	9	1928	M
70989	5	József	Bozsik	28	11	1925	M
70943	6	József	Zakariás	25	3	1924	M
23830	7	József	Tóth	16	5	1929	M
7028	8	Sándor	Kocsis	21	9	1929	M
1173	9	Nándor	Hidegkuti	3	3	1922	M
12676	10	Ferenc	Puskás	2	4	1927	M
93334	11	Zoltán	Czibor	8	8	1929	M
48019	12	Béla	Kárpáti	30	9	1929	M
15295	13	Pál	Várhidi	6	11	1931	M
28478	14	Imre	Kovács	26	11	1921	M
44025	15	Ferenc	Szojka	7	4	1931	M
29822	16	László	Budai	19	7	1928	M
97086	17	Ferenc	Machos	30	6	1932	M
46961	18	Lajos	Csordás	6	10	1932	M
42138	19	Péter	Palotás	27	6	1929	M
24411	20	Mihály	Tóth	24	9	1926	M
9102	21	Sándor	Gellér	12	7	1925	M
32482	22	Géza	Gulyás	5	6	1931	M
98482	1	Giorgio	Ghezzi	10	7	1930	M
89990	2	Guido	Vincenzi	14	7	1932	M
2078	3	Giovanni	Giacomazzi	18	1	1928	M
53641	4	Maino	Neri	30	6	1924	M
17534	6	Fulvio	Nesti	8	6	1925	M
32442	9	Carlo	Galli	6	3	1931	M
66232	12	Giovanni	Viola	26	6	1926	M
27061	13	Ardico	Magnini	21	10	1928	M
25424	14	Sergio	Cervato	22	3	1929	M
17792	16	Rino	Ferrario	7	12	1926	M
93415	17	Armando	Segato	3	5	1930	M
29194	18	Gino	Pivatelli	27	3	1933	M
7167	20	Guido	Gratton	23	9	1932	M
64967	21	Amleto	Frignani	5	3	1932	M
43291	22	Leonardo	Costagliola	27	10	1921	M
88284	2	Narciso	López	18	8	1928	M
84868	3	Jorge	Romo	20	4	1923	M
7090	4	Saturnino	Martínez	1	1	1928	M
53255	5	Raúl	Cárdenas	30	10	1928	M
20318	6	Rafael	Ávalos	22	11	1925	M
11635	7	Alfredo	Torres	31	5	1931	M
53183	9	José Luis	Lamadrid	3	7	1930	M
66576	10	Tomás	Balcázar	21	12	1931	M
12041	11	Raúl	Arellano	28	2	1935	M
87406	12	Salvador	Mota	30	11	1922	M
15310	13	Sergio	Bravo	27	11	1927	M
84531	14	Juan	Gómez	26	6	1924	M
54240	15	Carlos	Blanco	5	3	1927	M
46575	16	Pedro	Nájera	3	2	1929	M
81432	18	Carlos	Carus	6	10	1930	M
97314	19	Moises	Jinich	15	12	1927	M
45918	22	Ranulfo	Cortés	9	7	1934	M
78119	1	Fred	Martin	13	5	1929	M
39669	2	Willie	Cunningham	22	2	1925	M
35569	3	Jock	Aird	18	2	1926	M
25807	4	Bobby	Evans	16	7	1927	M
47080	5	Tommy	Docherty	24	4	1928	M
45574	6	Jimmy	Davidson	8	11	1925	M
70753	7	Doug	Cowie	1	5	1926	M
60694	8	John	Mackenzie	4	9	1925	M
28715	9	George	Hamilton	7	12	1917	M
9457	10	Allan	Brown	12	10	1926	M
15894	11	Neil	Mochan	6	4	1927	M
72928	12	Willie	Fernie	22	11	1928	M
70361	13	Willie	Ormond	23	2	1927	M
60745	14	John	Anderson	8	12	1929	M
4087	15	Bobby	Johnstone	7	9	1929	M
83598	16	Jackie	Henderson	17	1	1932	M
81374	17	David	Mathers	25	10	1931	M
42336	18	Alex	Wilson	29	10	1933	M
95817	19	Jimmy	Binning	25	7	1927	M
47525	20	Bobby	Combe	29	2	1924	M
52450	21	Ernie	Copland	15	4	1927	M
43964	22	Ian	McMillan	18	3	1931	M
6529	1	Deok-young	Hong	5	5	1921	M
36442	2	Kyu-chung	Park	12	6	1924	M
390	3	Jae-seung	Park	1	4	1923	M
22072	4	Chang-gi	Kang	28	8	1927	M
5606	5	Sang-yi	Lee	1	1	1922	M
80874	6	Byung-dae	Min	20	2	1918	M
85853	7	Soo-nam	Lee	2	2	1927	M
66707	8	Chung-min	Choi	30	8	1930	M
68644	9	Sang-kwon	Woo	2	2	1926	M
10808	10	Nak-woon	Sung	2	2	1926	M
4699	11	Nam-sik	Chung	16	2	1917	M
19652	12	Heung-chul	Ham	17	11	1930	M
4951	13	Jong-kap	Li	18	3	1920	M
10562	14	Chang-wha	Han	3	11	1922	M
15820	15	Ji-sung	Kim	7	11	1924	M
18513	16	Yung-kwang	Chu	15	7	1931	M
26638	17	Il-kap	Park	21	3	1926	M
87777	18	Yung-keun	Choi	8	2	1923	M
73309	19	Ki-joo	Li	12	11	1926	M
6524	20	Kook-chin	Chung	2	1	1917	M
64611	1	Walter	Eich	27	5	1925	M
5331	2	Eugene	Parlier	13	2	1929	M
20993	5	Marcel	Flückiger	20	6	1929	M
20604	6	Roger	Mathis	4	4	1921	M
60020	8	Heinz	Bigler	21	12	1925	M
53302	9	Charles	Casali	27	4	1923	M
9700	11	Norbert	Eschmann	19	9	1933	M
94112	12	Gilbert	Fesselet	16	4	1928	M
68231	13	Ivo	Frosio	27	4	1930	M
63738	16	Robert	Ballaman	21	6	1926	M
14406	18	Josef	Hügi	23	1	1930	M
51308	19	Marcel	Mauron	25	3	1929	M
46939	20	Eugen	Meier	30	4	1930	M
30328	21	Ferdinando	Riva	3	7	1930	M
30097	22	Roger	Vonlanthen	5	12	1930	M
9081	1	Turgay	Şeren	15	5	1932	M
90871	2	Rıdvan	Bolatlı	2	12	1928	M
9221	3	Basri	Dirimlili	7	6	1929	M
4447	4	Mustafa	Ertan	21	4	1926	M
88846	5	Çetin	Zeybek	12	9	1932	M
58180	6	Rober	Eryol	21	12	1930	M
15472	7	Erol	Keskin	2	3	1927	M
71884	8	Suat	Mamat	8	11	1930	M
15041	9	Feridun	Buğeker	5	4	1933	M
4515	10	Burhan	Sargun	11	2	1929	M
92456	11	Lefter	Küçükandonyadis	22	12	1925	M
38003	12	Şükrü	Ersoy	14	1	1934	M
25326	13	Bülent	Eken	1	1	1934	M
81979	14	Ali	Beratlıgil	21	10	1931	M
72128	15	Mehmet	Dinçer	1	1	1924	M
70566	16	Nedim	Günar	2	1	1932	M
88221	17	Naci	Erdem	28	1	1931	M
41399	18	Kaçmaz	Akgün	19	2	1935	M
53949	19	Ahmet	Berman	1	1	1932	M
72588	20	Necmi	Onarıcı	2	11	1925	M
71030	21	Kadri	Aytaç	6	8	1931	M
93253	22	Coşkun	Taş	23	4	1935	M
70798	2	José	Santamaría	31	7	1929	M
57200	6	Roberto	Leopardi	19	7	1933	M
78277	7	Julio	Abbadie	7	9	1930	M
10601	8	Juan	Hohberg	8	10	1926	M
90496	11	Carlos	Borges	14	1	1932	M
83575	12	Julio	Maceiras	22	4	1926	M
95472	13	Mirto	Davoine	13	2	1933	M
74898	15	Urbano	Rivera	1	4	1926	M
80644	16	Néstor	Carballo	3	2	1929	M
92883	17	Luis	Cruz	28	4	1925	M
93118	18	Rafael	Souto	24	10	1930	M
66683	19	Javier	Ambrois	9	5	1932	M
96652	20	Omar	Méndez	7	8	1934	M
13223	22	Luis	Castro	31	7	1921	M
37943	1	Toni	Turek	18	1	1919	M
39583	2	Fritz	Laband	1	11	1925	M
51214	3	Werner	Kohlmeyer	19	4	1924	M
61853	4	Hans	Bauer	28	7	1927	M
34121	5	Herbert	Erhardt	6	7	1930	M
61483	6	Horst	Eckel	8	2	1932	M
68778	7	Josef	Posipal	20	6	1927	M
53545	8	Karl	Mai	27	7	1928	M
9250	9	Paul	Mebus	9	6	1920	M
85009	10	Werner	Liebrich	18	1	1927	M
39750	11	Karl-Heinz	Metzner	9	1	1923	M
8136	12	Helmut	Rahn	16	8	1929	M
5766	13	Max	Morlock	11	5	1925	M
33698	14	Bernhard	Klodt	26	10	1926	M
71954	15	Ottmar	Walter	6	3	1924	M
9973	16	Fritz	Walter	31	10	1920	M
58241	17	Richard	Herrmann	28	1	1923	M
10374	18	Ulrich	Biesinger	6	8	1933	M
57739	19	Alfred	Pfaff	16	7	1926	M
63184	20	Hans	Schäfer	19	10	1927	M
80280	21	Heinz	Kubsch	20	7	1930	M
15476	22	Heinz	Kwiatkowski	16	7	1926	M
67864	3	Tomislav	Crnković	17	6	1929	M
81384	6	Vujadin	Boškov	16	5	1931	M
74352	11	Branko	Zebec	17	5	1929	M
52456	12	Branko	Kralj	10	3	1924	M
13610	13	Miljan	Zeković	15	11	1925	M
5550	14	Lav	Mantula	8	12	1928	M
70847	15	Ljubiša	Spajić	7	3	1926	M
44949	16	Sima	Milovanov	10	4	1923	M
43123	17	Bruno	Belin	16	1	1929	M
42	18	Miloš	Milutinović	5	2	1933	M
95843	19	Zlatko	Papec	17	1	1934	M
82751	20	Dionizije	Dvornić	27	4	1926	M
47783	21	Todor	Veselinović	22	10	1930	M
85317	22	Aleksandar	Petaković	6	2	1930	M
69090	1	Amadeo	Carrizo	12	6	1926	M
10583	2	Pedro	Dellacha	9	7	1926	M
11223	3	Federico	Vairo	27	1	1930	M
15145	4	Juan	Lombardo	11	6	1925	M
91035	5	Néstor	Rossi	10	5	1925	M
40725	6	José	Varacka	27	5	1932	M
71952	7	Oreste	Corbatta	11	3	1936	M
43944	8	Eliseo	Prado	17	9	1929	M
98280	9	Norberto	Menéndez	14	12	1936	M
35675	10	Alfredo	Rojas	20	2	1937	M
33713	11	Ángel	Labruna	28	9	1918	M
73082	12	Julio	Musimessi	9	7	1924	M
35217	13	Alfredo	Pérez	10	4	1929	M
60343	14	Federico	Edwards	25	1	1931	M
81409	15	David	Acevedo	20	2	1937	M
51757	16	Eliseo	Mouriño	3	6	1927	M
86786	17	José Ramón	Delgado	25	8	1935	M
22258	18	Norberto	Boggio	11	8	1931	M
20645	19	Ludovico	Avio	6	10	1932	M
58138	20	Ricardo	Infante	21	6	1924	M
46624	21	José	Sanfilippo	4	5	1935	M
19812	22	Osvaldo	Cruz	29	5	1931	M
82202	1	Rudolf	Szanwald	6	7	1931	M
3503	4	Franz	Swoboda	15	2	1933	M
57255	7	Walter	Horak	1	6	1931	M
5242	8	Paul	Kozlicek	22	7	1937	M
79204	9	Hans	Buzek	22	5	1938	M
4538	11	Helmut	Senekowitsch	22	10	1933	M
81537	14	Josef	Hamerl	22	1	1931	M
54866	17	Ernst	Kozlicek	27	1	1931	M
9741	20	Herbert	Ninaus	31	3	1937	M
51811	21	Ignaz	Puschnik	5	2	1934	M
69227	22	Bruno	Engelmeier	5	9	1927	M
70724	2	Hilderaldo	Bellini	7	6	1930	M
7056	3	not applicable	Gilmar	22	8	1930	M
7441	5	Dino	Sani	23	5	1932	M
38164	7	Mário	Zagallo	9	8	1931	M
82336	8	not applicable	Oreco	13	6	1932	M
39031	9	not applicable	Zózimo	19	6	1932	M
38906	10	not applicable	Pelé	23	10	1940	M
46080	11	not applicable	Garrincha	28	10	1933	M
7545	13	not applicable	Moacir	18	5	1936	M
20979	14	De	Sordi	14	2	1931	M
577	15	not applicable	Orlando	20	9	1935	M
40185	17	Joel Antônio	Martins	11	11	1931	M
60629	18	José	Altafini	24	7	1938	M
82525	19	not applicable	Zito	18	8	1932	M
45310	20	not applicable	Vavá	12	11	1934	M
27005	21	not applicable	Dida	26	3	1934	M
54379	22	not applicable	Pepe	25	2	1935	M
22974	2	Gustav	Mráz	11	9	1934	M
8277	3	Jiří	Čadek	7	12	1935	M
37610	5	Josef	Masopust	9	2	1931	M
65506	8	Milan	Dvořák	19	11	1934	M
90655	9	Pavol	Molnár	13	2	1936	M
16445	10	Jaroslav	Borovička	26	1	1931	M
71720	12	Zdeněk	Zikán	10	11	1937	M
28805	13	Václav	Hovorka	19	9	1931	M
45404	14	Jiří	Feureisl	3	10	1931	M
21516	16	Ján	Popluhár	12	9	1935	M
55526	17	Titus	Buberník	12	10	1933	M
82183	18	Adolf	Scherer	5	5	1938	M
70067	19	Břetislav	Dolejší	26	9	1928	M
39483	20	Anton	Moravčík	3	6	1931	M
6948	1	Colin	McDonald	15	10	1930	M
58940	2	Don	Howe	12	10	1935	M
42945	3	Tommy	Banks	10	11	1929	M
39670	4	Eddie	Clamp	14	9	1934	M
47763	6	Bill	Slater	29	4	1927	M
84663	7	Bryan	Douglas	27	5	1934	M
34086	8	Bobby	Robson	18	2	1933	M
60811	9	Derek	Kevan	6	3	1935	M
55839	12	Eddie	Hopkinson	29	10	1935	M
79975	13	Alan	Hodgkinson	16	8	1936	M
69171	14	Peter	Sillett	1	2	1933	M
17583	15	Ronnie	Clayton	5	8	1934	M
93416	16	Maurice	Norman	8	5	1934	M
300	17	Peter	Brabrook	8	11	1937	M
75118	18	Peter	Broadbent	15	5	1933	M
96877	19	Bobby	Smith	22	2	1933	M
8601	20	Bobby	Charlton	11	10	1937	M
35894	21	Alan	A'Court	30	9	1934	M
97832	22	Maurice	Setters	16	12	1936	M
56360	2	Dominique	Colonna	4	9	1928	M
23507	5	André	Lerond	6	12	1930	M
94935	7	Robert	Mouynet	25	3	1930	M
92981	8	Bernard	Chiarelli	24	2	1934	M
81510	9	Kazimir	Hnatow	9	1	1929	M
63080	11	Maurice	Lafont	13	9	1927	M
48323	14	Raymond	Bellot	9	6	1929	M
2130	15	Stéphane	Bruey	11	12	1932	M
8451	16	Yvon	Douis	16	5	1935	M
77939	17	Just	Fontaine	18	8	1933	M
86268	19	Célestin	Oliver	12	7	1930	M
38969	20	Roger	Piantoni	26	12	1931	M
75977	22	Maryan	Wisnieski	1	2	1937	M
61906	2	Sándor	Mátrai	20	11	1932	M
92656	3	Ferenc	Sipos	13	12	1932	M
44813	4	László	Sárosi	27	2	1932	M
73769	6	Pál	Berendy	30	11	1932	M
82971	8	Lajos	Tichy	21	3	1935	M
77346	10	Dezső	Bundzsák	3	5	1928	M
69885	11	Károly	Sándor	29	11	1928	M
83705	13	Oszkár	Szigeti	10	9	1933	M
78478	15	Antal	Kotász	1	9	1929	M
91386	16	László	Lachos	17	1	1933	M
99943	17	Mihály	Vasas	14	9	1933	M
78197	18	Tivadar	Monostori	24	8	1936	M
78802	19	Zoltán	Friedmanszky	22	10	1934	M
47384	20	József	Bencsics	6	8	1933	M
36108	21	Máté	Fenyvesi	20	9	1933	M
1406	22	István	Ilku	6	3	1933	M
75144	2	Jesús	del Muro	30	11	1937	M
56205	4	José	Villegas	20	6	1934	M
41805	5	Alfonso	Portugal	21	1	1934	M
70829	6	Francisco	Flores	12	2	1926	M
82053	7	Alfredo	Hernández	18	6	1935	M
92848	8	Salvador	Reyes	20	9	1936	M
90775	9	Carlos	Calderón de la Barca	2	10	1934	M
53579	10	Crescencio	Gutiérrez	26	10	1933	M
45721	11	Enrique	Sesma	22	4	1927	M
97290	12	Manuel	Camacho	29	4	1929	M
21324	13	Jaime	Gómez	29	12	1929	M
1211	14	Miguel	Gutiérrez	7	5	1931	M
63904	15	Guillermo	Sepúlveda	\N	\N	\N	M
96660	18	Jaime	Salazar	6	2	1931	M
10223	19	Jaime	Belmonte	8	10	1934	M
91558	21	Ligorio	López	3	7	1933	M
95498	22	Carlos	González	12	4	1935	M
82415	1	Harry	Gregg	27	10	1932	M
82190	2	Willie	Cunningham	20	2	1930	M
3683	3	Alf	McMichael	1	10	1927	M
13513	4	Danny	Blanchflower	10	2	1926	M
56108	5	Dick	Keith	15	5	1933	M
41288	6	Bertie	Peacock	29	9	1928	M
12780	7	Billy	Bingham	5	8	1931	M
36975	8	Wilbur	Cush	10	6	1928	M
79456	9	Billy	Simpson	12	12	1929	M
89933	10	Jimmy	McIlroy	25	10	1931	M
77851	11	Peter	McParland	25	4	1934	M
66051	12	Norman	Uprichard	20	4	1928	M
87116	13	Tommy	Casey	11	3	1930	M
81010	14	Jackie	Scott	22	12	1933	M
28578	15	Sammy	McCrory	11	10	1924	M
15853	16	Derek	Dougan	20	1	1938	M
20825	17	Fay	Coyle	1	4	1933	M
33683	18	Roy	Rea	28	11	1934	M
87420	19	Len	Graham	17	10	1925	M
82907	20	Sammy	Chapman	16	2	1938	M
87803	21	Tommy	Hamill	10	7	1933	M
72502	22	Bobby	Trainor	25	4	1934	M
31624	1	Ramón	Mayeregger	5	3	1936	M
15860	2	Edelmiro	Arévalo	7	1	1929	M
73770	3	Juan Vicente	Lezcano	5	4	1937	M
17442	4	Ignacio	Achúcarro	31	7	1936	M
11712	5	Salvador	Villalba	29	8	1924	M
25462	6	Eligio	Echagüe	31	12	1938	M
17292	7	Juan Bautista	Agüero	24	6	1935	M
22636	8	José	Parodi	30	8	1932	M
32438	9	Jorge Lino	Romero	23	9	1937	M
17727	10	Oscar	Aguilera	11	3	1935	M
19817	11	Florencio	Amarilla	3	1	1935	M
43460	12	Samuel	Aguilar	16	3	1933	M
85095	13	Luis	Gini	31	10	1935	M
98385	14	Darío	Segovia	18	3	1932	M
85798	15	Luis	Santos Silva	\N	\N	\N	M
88328	16	Claudio	Lezcano	\N	\N	\N	M
41977	17	Agustín	Miranda	1	1	1930	M
43310	18	Gilberto	Penayo	3	4	1933	M
33966	19	Eliseo	Insfrán	27	10	1935	M
86843	20	José Raúl	Aveiro	18	7	1936	M
65484	21	Cayetano	Ré	7	2	1938	M
32612	22	Eligio	Insfrán	27	10	1935	M
439	1	Tommy	Younger	10	4	1930	M
18281	2	Bill	Brown	8	10	1931	M
22201	3	Alex	Parker	2	8	1935	M
42014	4	Eric	Caldow	14	5	1934	M
79871	5	John	Hewie	13	12	1927	M
89367	6	Harry	Haddock	26	7	1925	M
70034	7	Ian	McColl	7	6	1927	M
87139	8	Eddie	Turnbull	12	4	1923	M
25161	11	Dave	Mackay	14	11	1934	M
73507	13	Sammy	Baird	13	5	1930	M
90549	14	Graham	Leggat	20	6	1934	M
76869	15	Alex	Scott	14	10	1984	M
7282	16	Jimmy	Murray	4	2	1933	M
19215	17	Jackie	Mudie	10	4	1930	M
13330	18	John	Coyle	28	9	1932	M
75309	19	Bobby	Collins	16	2	1931	M
91151	20	Archie	Robertson	15	9	1929	M
27462	21	Stewart	Imlach	6	1	1932	M
9317	1	Lev	Yashin	22	10	1929	M
48811	2	Vladimir	Kesarev	26	2	1930	M
33632	3	Konstantin	Krizhevsky	20	2	1926	M
49657	4	Boris	Kuznetsov	14	7	1928	M
69088	5	Yuri	Voinov	29	11	1931	M
65970	6	Igor	Netto	9	1	1930	M
35585	7	German	Apukhtin	12	6	1936	M
11702	8	Valentin	Ivanov	19	11	1934	M
54948	9	Nikita	Simonyan	12	10	1926	M
67694	10	Sergei	Salnikov	13	9	1925	M
80609	11	Anatoli	Ilyin	27	6	1931	M
92483	12	Vladimir	Maslachenko	5	3	1936	M
1959	13	Vladimir	Belyayev	15	9	1933	M
4392	14	Leonid	Ostrovskiy	17	1	1936	M
63158	15	Anatoli	Maslyonkin	26	6	1930	M
49145	16	Viktor	Tsarev	2	6	1931	M
92440	17	Aleksandr	Ivanov	14	4	1928	M
77966	18	Valentin	Bubukin	23	4	1933	M
87288	19	Gennadi	Gusarov	11	3	1937	M
45067	20	Yuri	Falin	2	4	1937	M
9442	21	Genrich	Fedosov	6	12	1932	M
68478	22	Vladimir	Yerokhin	10	4	1930	M
25529	2	Orvar	Bergmark	16	11	1930	M
8805	3	Sven	Axbom	15	10	1926	M
10338	4	Nils	Liedholm	8	10	1922	M
80056	5	Åke	Johansson	19	3	1928	M
42409	6	Sigge	Parling	26	3	1930	M
20173	7	Kurt	Hamrin	19	11	1934	M
69813	8	Gunnar	Gren	31	10	1920	M
82312	9	Agne	Simonsson	19	10	1935	M
44518	10	Arne	Selmosson	29	3	1931	M
63780	13	Prawitz	Öberg	16	11	1930	M
65514	14	Bengt	Gustavsson	15	1	1928	M
91855	15	Reino	Börjesson	4	2	1929	M
37296	16	Ingemar	Haraldsson	3	2	1928	M
21974	17	Olle	Håkansson	22	2	1927	M
81709	18	Gösta	Löfgren	29	8	1923	M
81023	19	Henry	Källgren	13	3	1931	M
12844	21	Bengt	Berndtsson	26	1	1933	M
92811	22	Owe	Ohlsson	19	8	1938	M
51617	1	Jack	Kelsey	19	11	1929	M
50023	2	Stuart	Williams	9	7	1930	M
78856	3	Mel	Hopkins	7	11	1934	M
66078	4	Derrick	Sullivan	10	8	1930	M
66610	5	Mel	Charles	14	5	1935	M
57163	6	Dave	Bowen	7	6	1928	M
90482	7	Terry	Medwin	25	9	1932	M
8340	8	Ron	Hewitt	21	6	1928	M
12687	9	John	Charles	27	12	1931	M
71223	10	Ivor	Allchurch	16	10	1929	M
29764	11	Cliff	Jones	7	2	1935	M
10948	12	Ken	Jones	2	1	1936	M
85966	13	Graham	Vearncombe	28	3	1934	M
72420	14	Trevor	Edwards	24	1	1937	M
27720	15	Colin	Baker	18	12	1934	M
49064	16	Vic	Crowe	31	1	1932	M
22295	17	Ken	Leek	26	7	1935	M
51500	18	Roy	Vernon	14	4	1937	M
89259	19	Colin	Webster	17	7	1932	M
8736	20	John	Elsworthy	26	7	1931	M
452	21	Len	Allchurch	12	9	1933	M
1974	22	George	Baker	6	4	1936	M
66256	1	Fritz	Herkenrath	9	9	1928	M
34271	3	Erich	Juskowiak	7	9	1926	M
5971	5	Heinz	Wewers	27	7	1927	M
55225	6	Horst	Szymaniak	29	8	1934	M
2292	7	Georg	Stollenwerk	19	12	1930	M
96191	10	Aki	Schmidt	5	9	1935	M
64138	12	Uwe	Seeler	5	11	1936	M
93539	14	Hans	Cieslarczyk	3	5	1937	M
11664	15	Alfred	Kelbassa	21	4	1925	M
6103	16	Hans	Sturm	3	9	1935	M
93072	17	Karl-Heinz	Schnellinger	31	3	1939	M
30065	18	Rudi	Hoffmann	11	2	1935	M
48102	19	Wolfgang	Peters	8	1	1929	M
45615	20	Hermann	Nuber	10	10	1935	M
24558	21	Günter	Sawitzki	22	11	1932	M
68158	2	Srboljub	Krivokuća	14	3	1928	M
76961	3	Vasilije	Šijaković	31	7	1929	M
92425	5	Novak	Tomić	7	1	1936	M
27264	8	Dobrosav	Krstić	5	2	1932	M
71169	10	Ivan	Šantek	23	4	1932	M
16586	11	Vladica	Popović	17	3	1935	M
52170	14	Milorad	Milutinović	10	3	1935	M
15756	15	Dragoslav	Šekularac	8	11	1937	M
32217	16	Ilijas	Pašić	10	5	1934	M
24259	17	Zdravko	Rajkov	5	12	1927	M
17091	18	Luka	Lipošinović	12	5	1933	M
47145	19	Radivoje	Ognjanović	1	7	1933	M
10089	20	Gordan	Irović	2	7	1934	M
44453	21	Nikola	Radović	10	3	1933	M
55024	22	Dražan	Jerković	6	8	1936	M
855	1	Antonio	Roma	13	7	1932	M
867	3	Silvio	Marzolini	4	10	1940	M
25685	4	Alberto	Sainz	13	12	1937	M
81303	5	Federico	Sacchi	9	8	1936	M
28121	6	Raúl	Páez	26	5	1937	M
14074	7	Héctor	Facundo	2	11	1937	M
18389	8	Martín	Pando	26	12	1934	M
71464	9	Marcelo	Pagani	19	8	1941	M
33017	11	Raúl	Belén	1	7	1931	M
84034	12	Rogelio	Domínguez	9	3	1932	M
47266	13	Oscar	Rossi	27	7	1930	M
34981	14	Alberto	Mariotti	23	8	1935	M
36583	15	Rubén	Navarro	11	3	1933	M
92300	16	Antonio	Rattín	16	5	1937	M
27099	17	Rafael	Albrecht	23	8	1941	M
96092	18	Vladislao	Cap	5	7	1934	M
27897	19	Rubén	Sosa	14	11	1936	M
90625	20	Juan Carlos	Oleniak	4	3	1942	M
32023	21	Ramón	Abeledo	29	4	1937	M
17625	22	Alberto	González	21	8	1941	M
87810	9	not applicable	Coutinho	11	6	1943	M
17125	12	Jair	Marinho	17	7	1936	M
76352	14	not applicable	Jurandir	12	11	1940	M
58585	15	not applicable	Altair	21	1	1938	M
89643	16	not applicable	Zequinha	18	11	1934	M
21480	17	not applicable	Mengálvio	17	12	1939	M
13437	18	Jair	da Costa	9	7	1940	M
96621	20	not applicable	Amarildo	29	6	1939	M
3284	1	Georgi	Naydenov	21	12	1931	M
88804	2	Kiril	Rakarov	24	5	1932	M
19802	3	Ivan	Dimitrov	14	5	1935	M
20700	4	Stoyan	Kitov	27	8	1938	M
80720	5	Dimitar	Kostov	26	7	1936	M
55242	6	Nikola	Kovachev	4	6	1934	M
3125	7	Todor	Diev	28	1	1934	M
31348	8	Dimitar	Dimov	13	12	1937	M
52425	9	Hristo	Iliev	11	5	1936	M
89534	10	Ivan	Kolev	1	11	1930	M
22594	11	Dimitar	Yakimov	12	8	1941	M
1172	12	Dobromir	Zhechev	12	11	1942	M
82222	13	Petar	Velichkov	8	8	1940	M
14962	14	Georgi	Sokolov	19	6	1942	M
72803	15	Georgi	Asparuhov	4	5	1943	M
76463	16	Aleksandar	Kostov	5	3	1938	M
46885	17	Panteley	Dimitrov	2	11	1940	M
90267	18	Ivan	Ivanov	1	1	1942	M
6520	19	Dinko	Dermendzhiev	2	6	1941	M
3916	20	Nikola	Parshanov	16	2	1934	M
88639	21	Panayot	Panayotov	30	12	1930	M
8847	22	Georgi	Nikolov	1	5	1931	M
747	1	Misael	Escuti	20	12	1926	M
15923	2	Luis	Eyzaguirre	22	6	1939	M
53489	3	Raúl	Sánchez	26	10	1933	M
51334	4	Sergio	Navarro	20	11	1936	M
79148	5	Carlos	Contreras	7	10	1938	M
65214	6	Eladio	Rojas	8	11	1934	M
98252	7	Jaime	Ramírez	14	8	1931	M
1618	8	Jorge	Toro	10	1	1939	M
87363	9	Honorino	Landa	1	6	1942	M
69887	10	Alberto	Fouilloux	22	11	1940	M
22224	11	Leonel	Sánchez	25	4	1936	M
80104	12	Adán	Godoy	26	11	1936	M
43288	13	Sergio	Valdés	11	5	1933	M
36467	14	Hugo	Lepe	14	4	1940	M
77566	15	Manuel	Rodríguez	18	1	1938	M
23529	16	Humberto	Cruz	8	12	1939	M
58900	17	Mario	Ortiz	28	1	1936	M
97048	18	Mario	Moreno	31	12	1935	M
52647	19	Braulio	Musso	8	3	1930	M
42198	20	Carlos	Campos	14	2	1937	M
4782	21	Armando	Tobar	7	6	1938	M
24782	22	Manuel	Astorga	15	5	1937	M
79242	1	Efraín	Sánchez	27	2	1926	M
60014	2	Achito	Vivas	1	3	1934	M
32148	3	Francisco	Zuluaga	4	2	1929	M
40750	4	Aníbal	Alzate	31	1	1933	M
75261	5	Jaime	González	1	4	1938	M
87249	6	Ignacio	Calle	21	8	1931	M
98630	7	Carlos	Aponte	24	1	1939	M
48377	8	Héctor	Echeverry	10	4	1938	M
16644	9	Jaime	Silva	10	10	1935	M
61986	10	Rolando	Serrano	13	11	1938	M
10418	11	Óscar	López	2	4	1939	M
38014	12	Hernando	Tovar	7	6	1938	M
17067	13	Germán	Aceros	30	9	1938	M
81306	14	Luis	Paz	25	6	1942	M
32950	15	Marcos	Coll	23	8	1935	M
9775	16	Ignacio	Pérez	19	12	1934	M
7544	17	Marino	Klinger	7	2	1936	M
79071	18	Eusebio	Escobar	2	7	1936	M
73967	19	Delio	Gamboa	28	1	1936	M
31841	20	Antonio	Rada	13	6	1937	M
37056	21	Héctor	González	7	7	1937	M
93894	22	Jairo	Arias	2	11	1938	M
10947	2	Jan	Lála	10	9	1936	M
53400	7	Jozef	Štibrányi	11	4	1940	M
34289	10	Jozef	Adamec	26	2	1942	M
26685	11	Josef	Jelínek	9	1	1941	M
46630	12	Jiří	Tichý	6	12	1933	M
63937	13	František	Schmucker	28	1	1940	M
88346	14	Václav	Mašek	21	3	1941	M
62981	15	Vladimír	Kos	9	8	1935	M
57430	17	Tomáš	Pospíchal	26	6	1936	M
90033	18	Josef	Kadraba	29	9	1933	M
25708	19	Andrej	Kvašňák	19	5	1936	M
69107	21	Pavel	Kouba	1	9	1938	M
22136	22	Jozef	Bomba	30	3	1939	M
22822	1	Ron	Springett	22	7	1935	M
44896	2	Jimmy	Armfield	21	9	1935	M
15317	3	Ray	Wilson	17	12	1934	M
10882	5	Peter	Swan	8	10	1936	M
5132	6	Ron	Flowers	28	7	1934	M
9806	7	John	Connelly	18	7	1938	M
75574	8	Jimmy	Greaves	20	2	1940	M
98541	9	Gerry	Hitchens	8	10	1934	M
42021	14	Stan	Anderson	27	2	1933	M
52816	16	Bobby	Moore	12	4	1941	M
33839	18	Roger	Hunt	20	7	1938	M
87143	19	Alan	Peacock	29	10	1937	M
97255	20	George	Eastham	23	9	1936	M
70505	22	Jimmy	Adamson	4	4	1929	M
95637	3	Kálmán	Mészöly	16	7	1941	M
1864	5	Ernő	Solymosi	21	9	1940	M
78670	8	János	Göröcs	8	5	1939	M
21188	9	Flórián	Albert	15	9	1941	M
93850	12	Kálmán	Sóvári	21	12	1940	M
52027	13	Kálmán	Ihász	6	3	1941	M
99498	14	István	Nagy	14	4	1939	M
1410	15	János	Mencel	14	12	1941	M
74113	16	János	Farkas	27	3	1942	M
30138	17	Gyula	Rákosi	9	10	1938	M
23218	19	Béla	Kuharszki	20	4	1940	M
4081	20	László	Bödör	17	8	1933	M
5681	21	Antal	Szentmihályi	13	6	1939	M
95875	1	Lorenzo	Buffon	19	12	1929	M
5300	2	Giacomo	Losi	9	11	1935	M
11175	3	Luigi	Radice	15	1	1935	M
97727	4	Sandro	Salvadore	29	11	1939	M
34023	5	Cesare	Maldini	5	2	1932	M
53115	6	Giovanni	Trapattoni	17	3	1939	M
14709	7	Bruno	Mora	29	3	1937	M
80419	8	Humberto	Maschio	20	2	1933	M
12682	10	Omar	Sívori	2	10	1935	M
34797	11	Giampaolo	Menichelli	29	6	1938	M
40979	12	Carlo	Mattrel	14	4	1937	M
73673	13	Enrico	Albertosi	2	11	1939	M
62214	14	Gianni	Rivera	18	8	1943	M
39599	15	Angelo	Sormani	3	7	1939	M
31011	16	Enzo	Robotti	13	6	1935	M
50486	17	Ezio	Pascutti	1	6	1937	M
29660	18	Mario	David	3	1	1934	M
89616	19	Francesco	Janich	27	3	1937	M
92379	20	Paride	Tumburus	8	3	1939	M
37836	21	Giorgio	Ferrini	18	8	1939	M
72738	22	Giacomo	Bulgarelli	24	10	1940	M
32063	7	Alfredo	del Águila	3	1	1935	M
61576	9	Héctor	Hernández	6	12	1935	M
52254	10	Guillermo	Ortiz Camargo	25	6	1939	M
5631	11	Isidoro	Díaz	14	3	1938	M
76847	13	Arturo	Chaires	14	3	1937	M
87807	14	Pedro	Romero	12	4	1937	M
48537	15	Ignacio	Jáuregui	31	7	1938	M
9921	16	Salvador	Farfán	22	6	1932	M
12371	17	Felipe	Ruvalcaba	16	2	1941	M
47450	19	Antonio	Jasso	11	3	1935	M
32657	20	Mario	Velarde	29	3	1940	M
70795	21	Alberto	Baeza	6	12	1938	M
62196	22	Antonio	Mota	26	1	1939	M
56493	3	Sergey	Kotrikadze	9	8	1936	M
70032	4	Eduard	Dubinski	6	4	1935	M
68508	5	Givi	Chokheli	27	6	1937	M
28651	8	Albert	Shesternyov	20	6	1941	M
35635	9	Nikolai	Manoshin	6	3	1938	M
22661	11	Yozhef	Sabo	29	2	1940	M
63252	12	Valery	Voronin	17	7	1939	M
63122	15	Viktor	Kanevski	3	10	1936	M
3441	16	Aleksei	Mamykin	29	2	1936	M
45798	17	Mikhail	Meskhi	12	1	1937	M
19936	18	Slava	Metreveli	30	5	1936	M
5819	19	Viktor	Ponedelnik	22	5	1937	M
60181	20	Viktor	Serebryanikov	29	3	1940	M
57969	21	Galimzyan	Khusainov	27	6	1937	M
38721	22	Igor	Chislenko	4	1	1939	M
58349	1	José	Araquistáin	4	3	1937	M
39089	2	Salvador	Sadurní	3	4	1941	M
90224	3	not applicable	Carmelo	6	12	1930	M
61299	4	Enrique	Collar	2	11	1934	M
80578	5	Luis	del Sol	6	4	1935	M
34403	6	Alfredo	Di Stéfano	4	7	1926	M
987	7	Luis María	Echeberría	24	3	1940	M
31306	8	Jesús	Garay	10	9	1930	M
9022	9	Francisco	Gento	21	10	1933	M
12970	10	Sígfrid	Gràcia	27	3	1932	M
82150	11	Feliciano	Rivilla	21	8	1936	M
15268	12	Joaquín	Peiró	29	1	1936	M
89577	13	not applicable	Pachín	28	12	1938	M
93628	15	Eulogio	Martínez	11	6	1935	M
59058	16	Severino	Reija	25	11	1938	M
81323	17	not applicable	Rodri	8	3	1934	M
3894	18	not applicable	Adelardo	26	9	1939	M
61313	20	Joan	Segarra	15	11	1927	M
39055	21	Luis	Suárez	2	5	1935	M
941	22	Martí	Vergés	8	3	1934	M
70926	1	Karl	Elsener	13	8	1934	M
73008	2	Antonio	Permunian	15	8	1930	M
32477	3	Kurt	Stettler	21	8	1932	M
92709	5	Fritz	Morf	29	1	1928	M
33226	6	Peter	Rösch	15	9	1930	M
99095	7	Heinz	Schneiter	12	4	1935	M
95816	8	Ely	Tacchella	25	5	1936	M
55057	9	André	Grobéty	22	6	1933	M
36812	10	Fritz	Kehl	12	7	1937	M
793	12	Marcel	Vonlanthen	8	9	1933	M
32732	13	Hans	Weber	8	9	1934	M
14618	14	Anton	Allemann	6	1	1936	M
52416	16	Richard	Dürr	1	12	1938	M
14930	18	Philippe	Pottier	9	7	1938	M
58469	19	Gilbert	Rey	30	10	1930	M
25619	21	Rolf	Wüthrich	4	9	1938	M
57789	22	Roberto	Frigerio	16	5	1938	M
83945	1	Roberto	Sosa	14	6	1935	M
11119	2	Horacio	Troche	14	2	1936	M
36059	3	Emilio	Álvarez	10	2	1939	M
96412	4	Mario	Méndez	11	5	1938	M
41691	5	Néstor	Gonçalves	27	4	1936	M
28196	6	Pedro	Cubilla	25	5	1933	M
4270	7	Domingo	Pérez	7	6	1936	M
82186	8	Julio César	Cortés	29	3	1941	M
15857	9	José	Sasía	27	12	1933	M
47892	10	Pedro	Rocha	3	12	1942	M
81929	11	Luis	Cubilla	28	3	1940	M
30655	12	Luis	Maidana	24	2	1934	M
89509	15	Rubén	Soria	23	1	1935	M
72837	16	Edgardo	González	30	9	1936	M
92902	17	Rubén	González	17	7	1939	M
89353	18	Eliseo	Álvarez	9	8	1940	M
5619	19	Ronald	Langón	6	8	1939	M
4101	20	Mario	Bergara	1	12	1937	M
77314	21	Héctor	Silva	1	2	1940	M
35342	22	Ángel	Cabrera	9	10	1939	M
82133	23	Guillermo	Escalada	24	4	1936	M
35661	1	Hans	Tilkowski	12	7	1935	M
77426	4	Willi	Schulz	4	10	1938	M
41116	5	Leo	Wilden	3	7	1936	M
41843	7	Willi	Koslowski	17	2	1937	M
12272	8	Helmut	Haller	21	7	1939	M
12917	10	Albert	Brülls	26	3	1937	M
83060	12	Hans	Nowak	9	8	1937	M
48317	13	Jürgen	Kurbjuhn	26	7	1940	M
65688	14	Jürgen	Werner	15	8	1935	M
27606	15	Willi	Giesemann	2	9	1937	M
24131	17	Engelbert	Kraus	30	7	1934	M
19353	18	Günther	Herrmann	1	9	1939	M
48720	19	Heinz	Strehl	20	7	1938	M
10351	20	Heinz	Vollmar	26	4	1936	M
98864	22	Wolfgang	Fahrian	31	5	1941	M
50189	1	Milutin	Šoškić	31	12	1937	M
38654	2	Vladimir	Durković	6	11	1937	M
32623	3	Fahrudin	Jusufi	8	12	1939	M
67185	4	Petar	Radaković	2	2	1937	M
15585	5	Vlatko	Marković	1	1	1937	M
64450	7	Andrija	Anković	16	7	1937	M
5537	10	Milan	Galić	8	3	1938	M
47998	11	Josip	Skoblar	12	3	1941	M
39332	13	Slavko	Svinjarević	16	4	1935	M
47431	15	Željko	Matuš	9	8	1935	M
3917	16	Muhamed	Mujić	25	4	1933	M
55272	17	Vojislav	Melić	5	1	1940	M
66765	18	Vladica	Kovačević	7	1	1940	M
78976	19	Mirko	Stojanović	11	6	1939	M
4783	20	Žarko	Nikolić	16	10	1938	M
9067	21	Nikola	Stipić	18	12	1937	M
33786	22	Aleksandar	Ivoš	28	6	1931	M
62756	2	Rolando	Irusta	27	3	1938	M
21555	3	Hugo	Gatti	19	8	1944	M
94783	4	Roberto	Perfumo	3	10	1942	M
53257	6	Oscar	Calics	18	11	1939	M
5616	8	Roberto	Ferreiro	25	4	1935	M
61271	9	Carmelo	Simeone	22	9	1934	M
42100	11	José Omar	Pastoriza	23	5	1942	M
49889	13	Nelson	López	24	6	1941	M
44727	14	Mario	Chaldú	6	6	1942	M
62533	15	Jorge	Solari	11	11	1941	M
46231	17	Juan Carlos	Sarnari	22	1	1942	M
47496	19	Luis	Artime	2	12	1938	M
20306	20	Ermindo	Onega	30	4	1940	M
97042	21	Oscar	Más	29	10	1946	M
95542	22	Aníbal	Tarabini	4	8	1941	M
18102	3	not applicable	Fidélis	13	3	1944	M
59934	5	not applicable	Brito	9	8	1939	M
86293	8	Paulo	Henrique	5	1	1943	M
84905	9	not applicable	Rildo	23	1	1942	M
4354	11	not applicable	Gérson	11	1	1941	M
39644	12	not applicable	Manga	26	4	1937	M
34746	13	not applicable	Denílson	28	3	1943	M
40151	14	not applicable	Lima	18	1	1942	M
77430	17	not applicable	Jairzinho	25	12	1944	M
66524	18	not applicable	Alcindo	16	12	1945	M
93168	19	not applicable	Silva	2	1	1940	M
53202	20	not applicable	Tostão	25	1	1947	M
66939	21	not applicable	Paraná	21	3	1942	M
49805	22	not applicable	Edu	6	8	1949	M
53019	2	Aleksandar	Shalamanov	4	9	1941	M
7046	3	Ivan	Vutsov	14	12	1939	M
66746	4	Boris	Gaganelov	7	10	1941	M
59856	5	Dimitar	Penev	12	7	1945	M
26899	10	Petar	Zhekov	10	10	1944	M
67000	12	Vasil	Metodiev	6	1	1935	M
1235	14	Nikola	Kotkov	9	12	1938	M
5257	15	Dimitar	Largov	10	9	1936	M
4189	17	Stefan	Abadzhiev	3	7	1934	M
12058	18	Evgeni	Yanchovski	5	9	1939	M
94330	19	Vidin	Apostolov	17	10	1941	M
92893	20	Ivan	Davidov	5	10	1943	M
66734	21	Simeon	Simeonov	26	4	1946	M
79047	22	Ivan	Deyanov	16	12	1937	M
47391	1	Pedro	Araya	23	1	1942	M
77734	2	Hugo	Berly	31	12	1941	M
98099	5	Humberto	Donoso	9	10	1938	M
95834	7	Elías	Figueroa	25	10	1946	M
52787	10	Roberto	Hodge	30	7	1944	M
83441	12	Rubén	Marcos	6	12	1942	M
61074	13	Juan	Olivares	20	2	1941	M
33539	14	Ignacio	Prieto	23	9	1943	M
6141	16	Orlando	Ramírez	7	5	1943	M
39340	19	Francisco	Valdés	19	3	1943	M
24618	20	Alberto	Valentini	25	11	1938	M
42080	21	Hugo	Villanueva	9	4	1939	M
27288	22	Guillermo	Yávar	26	3	1943	M
74455	1	Gordon	Banks	30	12	1937	M
56457	2	George	Cohen	22	10	1939	M
34887	4	Nobby	Stiles	18	5	1942	M
43761	5	Jack	Charlton	8	5	1935	M
22841	7	Alan	Ball	12	5	1945	M
34802	10	Geoff	Hurst	8	12	1941	M
25979	13	Peter	Bonetti	27	9	1941	M
64663	15	Gerry	Byrne	29	8	1938	M
34233	16	Martin	Peters	8	11	1943	M
70457	18	Norman	Hunter	29	10	1943	M
1287	19	Terry	Paine	23	3	1939	M
49523	20	Ian	Callaghan	10	4	1942	M
3644	1	Marcel	Aubour	17	6	1940	M
15235	2	Marcel	Artelesa	2	7	1938	M
43085	3	Edmond	Baraffe	19	10	1942	M
90417	4	Joseph	Bonnel	4	1	1939	M
53136	5	Bernard	Bosquier	19	6	1942	M
94477	6	Robert	Budzynski	21	5	1940	M
8286	7	André	Chorda	20	2	1938	M
98706	8	Nestor	Combin	29	12	1940	M
57925	9	Didier	Couécou	25	7	1944	M
39420	10	Héctor	De Bourgoing	23	7	1934	M
20709	11	Gabriel	De Michele	6	3	1941	M
86721	12	Jean	Djorkaeff	27	10	1939	M
93859	13	Philippe	Gondet	17	5	1942	M
5248	14	Gérard	Hausser	18	3	1939	M
59228	15	Yves	Herbet	17	8	1945	M
77479	16	Robert	Herbin	30	3	1939	M
41229	17	Lucien	Muller	3	9	1934	M
17245	18	Jean-Claude	Piumi	27	5	1940	M
3840	19	Laurent	Robuschi	5	10	1935	M
94089	20	Jacques	Simon	25	3	1941	M
95105	21	Georges	Carnus	13	8	1942	M
46980	22	Johnny	Schuth	7	12	1941	M
34606	2	Benő	Káposzta	7	6	1942	M
82516	7	Ferenc	Bene	17	12	1944	M
88739	8	Zoltán	Varga	1	1	1945	M
55221	13	Imre	Mathesz	25	3	1937	M
35206	15	Dezső	Molnár	2	12	1939	M
49366	17	Gusztáv	Szepesi	17	7	1939	M
82931	19	Lajos	Puskás	3	8	1944	M
7203	20	Antal	Nagy	16	5	1944	M
32722	21	József	Gelei	29	6	1938	M
64569	22	István	Géczi	13	6	1944	M
8972	2	Roberto	Anzolin	18	4	1938	M
1013	3	Paolo	Barison	23	6	1936	M
42540	5	Tarcisio	Burgnich	25	4	1939	M
68170	6	Giacinto	Facchetti	18	7	1942	M
11488	7	Romano	Fogli	21	1	1938	M
18770	8	Aristide	Guarneri	7	3	1938	M
68792	10	Antonio	Juliano	1	1	1943	M
35433	11	Spartaco	Landini	31	1	1944	M
27425	12	Gianfranco	Leoncini	25	9	1939	M
46187	13	Giovanni	Lodetti	10	8	1942	M
91195	14	Sandro	Mazzola	8	11	1942	M
77332	15	Luigi	Meroni	24	2	1943	M
73715	17	Marino	Perani	27	10	1939	M
59807	18	Pierluigi	Pizzaballa	14	9	1939	M
91752	20	Francesco	Rizzo	30	5	1943	M
45085	21	Roberto	Rosato	18	8	1943	M
64553	3	Gustavo	Peña	22	11	1941	M
91914	8	Aarón	Padilla	10	7	1942	M
85684	9	Ernesto	Cisneros	26	10	1940	M
48001	10	Javier	Fragoso	19	4	1942	M
37767	11	Francisco	Jara	3	2	1941	M
66980	12	Ignacio	Calderón	13	12	1943	M
13602	13	José Luis	González	14	9	1942	M
35938	14	Gabriel	Núñez	6	2	1942	M
69898	15	Guillermo	Hernández	25	6	1942	M
93728	16	Luis	Regueiro	22	12	1943	M
29553	17	Magdaleno	Mercado	4	4	1944	M
28249	18	Elías	Muñoz	3	11	1941	M
55734	20	Enrique	Borja	30	12	1945	M
65845	21	Ramiro	Navarro	25	5	1943	M
4130	22	Javier	Vargas	22	11	1941	M
36838	1	Chang-myung	Lee	2	1	1947	M
48502	2	Li-sup	Pak	6	1	1944	M
67273	3	Yung-kyoo	Shin	30	3	1942	M
6709	4	Bong-chil	Kang	7	11	1943	M
61086	5	Zoong-sun	Lim	16	7	1943	M
480	6	Seung-hwi	Im	3	2	1946	M
64788	7	Doo-ik	Pak	17	3	1942	M
87203	8	Seung-zin	Pak	11	1	1941	M
60695	9	Keun-hak	Lee	7	7	1940	M
11641	10	Ryong-woon	Kang	25	4	1942	M
50323	11	Bong-zin	Han	2	9	1945	M
40283	12	Seung-Il	Kim	2	9	1945	M
40761	13	Yoon-kyung	Oh	6	8	1941	M
6724	14	Jung-won	Ha	20	4	1942	M
59059	15	Seung-kook	Yang	19	8	1944	M
45281	16	Dong-woon	Li	4	7	1945	M
52780	17	Bong-hwan	Kim	4	7	1939	M
70204	18	Seung-woon	Ke	26	12	1943	M
88081	19	Yung-kil	Kim	29	1	1944	M
27004	20	Chang-kil	Ryoo	5	11	1940	M
3861	21	Se-bok	An	29	10	1946	M
74112	22	Chi-an	Li	7	7	1945	M
44487	1	not applicable	Américo	6	3	1933	M
67001	2	Joaquim	Carvalho	18	4	1937	M
91257	3	José	Pereira	15	9	1931	M
53884	4	not applicable	Vicente	24	9	1935	M
44233	5	not applicable	Germano	18	1	1933	M
70918	6	Fernando	Peres	8	1	1942	M
13304	7	Ernesto	Figueiredo	6	7	1937	M
74248	8	João	Lourenço	8	4	1942	M
39642	9	not applicable	Hilário	19	3	1939	M
3493	10	Mário	Coluna	6	8	1935	M
60225	11	António	Simões	14	12	1943	M
67663	12	José	Augusto	13	4	1937	M
74747	13	not applicable	Eusébio	25	1	1942	M
64664	14	Fernando	Cruz	12	8	1940	M
79162	15	Manuel	Duarte	20	5	1943	M
44642	16	Jaime	Graça	10	1	1942	M
36538	17	João	Morais	6	3	1935	M
68398	18	José	Torres	8	9	1938	M
24730	19	Custódio	Pinto	9	2	1942	M
58433	20	Alexandre	Baptista	17	2	1941	M
9642	21	José	Carlos	22	9	1941	M
60146	22	Alberto	Festa	21	7	1939	M
36991	4	Vladimir	Ponomaryov	18	2	1940	M
76618	5	Valentin	Afonin	22	12	1939	M
90524	7	Murtaz	Khurtsilava	5	1	1943	M
60231	9	Viktor	Getmanov	4	5	1940	M
40669	10	Vasiliy	Danilov	13	5	1941	M
99442	13	Alexey	Korneyev	6	2	1939	M
24268	14	Georgi	Sichinava	15	9	1944	M
53800	17	Valeriy	Porkujan	4	10	1944	M
44798	18	Anatoliy	Banishevskiy	23	2	1946	M
83456	19	Eduard	Malofeyev	2	6	1942	M
87023	20	Eduard	Markarov	20	6	1942	M
79597	21	Anzor	Kavazashvili	19	7	1940	M
91040	22	Viktor	Bannikov	28	4	1938	M
61200	1	José Ángel	Iribar	1	3	1943	M
50021	2	Manuel	Sanchís	26	3	1938	M
50137	3	not applicable	Eladio	18	11	1940	M
42046	5	Ignacio	Zoco	31	7	1939	M
48822	6	Jesús	Glaría	2	1	1942	M
5221	7	José	Ufarte	17	5	1941	M
80285	8	not applicable	Amancio	16	10	1939	M
49138	9	not applicable	Marcelino	29	4	1940	M
93882	12	Antonio	Betancort	13	3	1938	M
45285	13	Miguel	Reina	24	1	1946	M
3159	16	Ferran	Olivella	22	6	1936	M
8045	17	not applicable	Gallego	4	3	1944	M
58423	18	not applicable	Pirri	11	3	1945	M
53638	19	Josep Maria	Fusté	15	4	1941	M
34577	22	Carlos	Lapetra	29	11	1938	M
71588	2	Willy	Allemann	10	6	1942	M
93161	3	Kurt	Armbruster	16	9	1934	M
20138	4	Heinz	Bäni	18	11	1936	M
81281	5	René	Brodmann	25	10	1933	M
48137	7	Hansruedi	Führer	24	12	1937	M
57315	8	Vittore	Gottardi	24	9	1941	M
20997	10	Robert	Hosp	13	12	1939	M
73866	11	Köbi	Kuhn	12	10	1943	M
11454	12	Léo	Eichmann	24	12	1936	M
53124	13	Fritz	Künzli	8	1	1946	M
69289	14	Werner	Leimgruber	2	9	1934	M
70292	15	Karl	Odermatt	17	12	1942	M
42555	16	René-Pierre	Quentin	5	8	1943	M
836	17	Jean-Claude	Schindelholz	11	10	1940	M
1529	19	Xavier	Stierli	29	10	1940	M
98546	21	Georges	Vuilleumier	21	9	1944	M
95773	22	Mario	Prosperi	4	8	1945	M
53140	1	Ladislao	Mazurkiewicz	14	2	1945	M
41231	3	Jorge	Manicera	4	11	1938	M
34358	4	Pablo	Forlán	14	7	1945	M
30744	6	Omar	Caetano	8	11	1938	M
63431	8	José	Urruzmendi	25	8	1944	M
18360	13	Nelson	Díaz	12	1	1942	M
63224	15	Luis	Ubiña	7	6	1940	M
3368	17	Héctor	Salvá	27	11	1939	M
22700	18	Milton	Viera	11	5	1946	M
98414	20	Luis	Ramos	9	10	1939	M
99710	21	Víctor	Espárrago	6	10	1944	M
61834	22	Walter	Taibo	7	3	1931	M
28162	2	Horst-Dieter	Höttges	10	9	1943	M
72864	4	Franz	Beckenbauer	11	9	1945	M
11099	6	Wolfgang	Weber	26	6	1944	M
86276	10	Sigfried	Held	7	8	1942	M
32446	11	Lothar	Emmerich	29	11	1941	M
60896	12	Wolfgang	Overath	29	9	1943	M
5324	13	Heinz	Hornig	28	9	1937	M
19519	14	Friedel	Lutz	21	1	1939	M
83141	15	Bernd	Patzke	14	3	1943	M
86015	16	Max	Lorenz	19	8	1939	M
55399	17	Wolfgang	Paul	25	1	1940	M
50033	18	Klaus-Dieter	Sieloff	27	2	1942	M
71648	19	Werner	Krämer	23	1	1940	M
48733	20	Jürgen	Grabowski	7	7	1944	M
85955	21	Günter	Bernard	4	11	1939	M
14080	22	Sepp	Maier	28	2	1944	M
92631	1	Christian	Piot	4	10	1947	M
23037	2	Georges	Heylens	8	8	1941	M
98745	3	Jean	Thissen	21	4	1946	M
23879	4	Nicolas	Dewalque	20	9	1945	M
77985	5	Léon	Jeck	9	2	1947	M
74479	6	Jean	Dockx	24	5	1941	M
67478	7	Léon	Semmeling	4	1	1940	M
47829	8	Wilfried	Van Moer	1	3	1945	M
89771	9	Johan	Devrindt	14	4	1944	M
94646	10	Paul	Van Himst	2	10	1943	M
67309	11	Wilfried	Puis	18	2	1943	M
69901	12	Jean-Marie	Trappeniers	13	1	1942	M
47589	13	Jacques	Beurlet	21	12	1944	M
43522	14	Maurice	Martens	5	6	1947	M
43168	15	Erwin	Vandendaele	5	3	1945	M
42364	16	Odilon	Polleunis	1	5	1943	M
13390	17	Jan	Verheyen	9	7	1944	M
59854	18	Raoul	Lambert	20	10	1944	M
69323	19	Pierre	Carteus	24	9	1943	M
69996	20	Alfons	Peeters	21	1	1943	M
77729	21	Frans	Janssens	25	9	1945	M
62963	22	Jacques	Duquesne	22	4	1940	M
39749	1	not applicable	Félix	24	12	1937	M
2965	3	not applicable	Piazza	25	2	1943	M
25829	4	Carlos	Alberto	17	7	1944	M
14923	5	not applicable	Clodoaldo	26	9	1949	M
15663	6	Marco	Antônio	6	2	1951	M
85778	11	not applicable	Rivellino	1	1	1946	M
47010	12	not applicable	Ado	4	7	1946	M
97113	13	not applicable	Roberto	31	7	1944	M
87388	14	not applicable	Baldocchi	14	3	1946	M
17395	15	not applicable	Fontana	31	12	1940	M
27277	16	not applicable	Everaldo	11	9	1944	M
34222	17	not applicable	Joel	18	9	1946	M
65181	18	not applicable	Caju	16	6	1949	M
3810	20	not applicable	Dario	4	3	1946	M
72683	21	not applicable	Zé Maria	18	5	1949	M
6015	22	not applicable	Leão	11	7	1949	M
30493	4	Stefan	Aladzhov	18	10	1947	M
2372	7	Georgi	Popov	14	7	1944	M
63835	8	Hristo	Bonev	3	2	1947	M
47776	12	Milko	Gaydarski	18	3	1946	M
18674	13	Stoyan	Yordanov	29	1	1944	M
45469	16	Asparuh	Nikodimov	21	8	1945	M
15241	17	Todor	Kolev	29	4	1942	M
28376	18	Dimitar	Marashliev	31	8	1947	M
27243	20	Vasil	Mitkov	17	9	1943	M
99127	21	Bozhidar	Grigorov	27	7	1945	M
92968	22	Georgi	Kamenski	3	2	1947	M
15216	1	Ivo	Viktor	21	5	1942	M
49133	2	Karol	Dobiaš	18	12	1947	M
95896	3	Václav	Migas	16	9	1944	M
22118	4	Vladimír	Hagara	7	11	1943	M
88857	5	Alexander	Horváth	28	12	1938	M
37315	7	Bohumil	Veselý	18	6	1945	M
61272	8	Ladislav	Petráš	1	12	1946	M
43628	9	Ladislav	Kuna	3	4	1947	M
31552	11	Karol	Jokl	29	8	1945	M
99091	12	Ján	Pivarník	13	11	1947	M
21149	13	Anton	Flešár	8	5	1944	M
4640	14	Vladimír	Hrivnák	23	4	1945	M
43520	15	Ján	Zlocha	24	3	1942	M
48978	16	Ivan	Hrdlička	20	11	1943	M
46923	17	Jaroslav	Pollák	11	7	1947	M
33536	18	František	Veselý	7	12	1943	M
94047	19	Josef	Jurkanin	5	3	1949	M
6647	20	Milan	Albrecht	16	7	1950	M
90487	21	Ján	Čapkovič	11	1	1948	M
17536	22	Alexander	Vencel	8	2	1944	M
8268	1	Raúl	Magaña	24	2	1940	M
86	2	Roberto	Rivas	17	7	1941	M
60582	3	Salvador	Mariona	16	12	1943	M
54377	4	Santiago	Cortés	19	1	1945	M
33258	5	Saturnino	Osorio	6	1	1945	M
2166	6	José	Quintanilla	29	10	1947	M
83098	7	Mauricio	Rodríguez	12	9	1945	M
16270	8	Jorge	Vásquez	23	4	1945	M
49544	9	Juan Ramón	Martínez	20	4	1948	M
10096	10	Salvador	Cabezas	28	2	1947	M
24464	11	Ernesto	Aparicio	28	12	1948	M
58367	12	Mario	Monge	27	11	1938	M
4639	13	Tomás	Pineda	21	1	1946	M
98965	14	Mauricio	Manzano	30	9	1943	M
70115	15	David	Cabrera	12	9	1945	M
86181	16	Genaro	Sarmeno	28	11	1948	M
65859	17	Jaime	Portillo	18	9	1947	M
87801	18	Guillermo	Castro	25	6	1940	M
55432	19	Sergio	Méndez	14	2	1942	M
10061	20	Gualberto	Fernández	12	7	1941	M
28429	21	Elmer	Acevedo	24	2	1946	M
56225	22	Alberto	Villalta	19	11	1947	M
79568	2	Keith	Newton	23	6	1941	M
40921	3	Terry	Cooper	12	7	1944	M
62668	4	Alan	Mullery	23	11	1941	M
49952	5	Brian	Labone	23	1	1940	M
88728	7	Francis	Lee	29	4	1944	M
43486	13	Alex	Stepney	18	9	1942	M
22176	14	Tommy	Wright	21	10	1944	M
63494	16	Emlyn	Hughes	28	8	1947	M
77223	19	Colin	Bell	26	2	1946	M
11917	20	Peter	Osgood	20	2	1947	M
52978	21	Allan	Clarke	31	7	1946	M
27328	22	Jeff	Astle	13	5	1942	M
9393	1	Yitzchak	Vissoker	18	9	1944	M
8449	2	Shraga	Bar	24	3	1948	M
92635	3	Menachem	Bello	26	12	1947	M
87631	4	David	Primo	5	5	1946	M
78005	5	Zvi	Rosen	23	6	1947	M
94998	6	Shmuel	Rosenthal	22	4	1947	M
95383	7	Itzhak	Shum	1	9	1948	M
62232	8	Giora	Spiegel	27	7	1947	M
95869	9	Yehoshua	Feigenbaum	5	12	1947	M
77834	10	Mordechai	Spiegler	19	8	1944	M
22729	11	George	Borba	12	7	1944	M
10922	12	Yisha'ayahu	Schwager	10	2	1946	M
14437	13	Yechezekel	Chazom	1	1	1947	M
37385	14	Danny	Shmulevich-Rom	29	11	1940	M
86314	15	Rachamim	Talbi	17	5	1943	M
60216	16	Yochanan	Vollach	14	5	1945	M
75509	17	Eli	Ben Rimoz	20	11	1944	M
43630	18	Moshe	Romano	6	5	1946	M
91215	19	Roni	Shuruk	24	2	1946	M
39275	20	David	Karako	11	2	1945	M
18748	21	Yechiel	Hameiri	20	8	1946	M
66373	22	Yair	Nossovsky	29	6	1937	M
56668	4	Fabrizio	Poletti	13	7	1943	M
53189	5	Pierluigi	Cera	25	2	1941	M
28851	6	Ugo	Ferrante	18	7	1945	M
77413	7	Comunardo	Niccolai	15	12	1946	M
3206	9	Giorgio	Puia	8	3	1938	M
72033	10	Mario	Bertini	7	1	1944	M
119	11	Gigi	Riva	7	11	1944	M
48831	12	Dino	Zoff	28	2	1942	M
67671	13	Angelo	Domenghini	25	8	1941	M
77530	16	Giancarlo	De Sisti	13	3	1943	M
68967	17	Lido	Vieri	16	7	1939	M
86117	19	Sergio	Gori	24	2	1946	M
92154	20	Roberto	Boninsegna	13	11	1943	M
5329	21	Giuseppe	Furino	5	7	1946	M
63857	22	Pierino	Prati	13	12	1946	M
80210	2	Juan Manuel	Alejandrez	17	5	1944	M
36154	4	Francisco	Montes	22	4	1943	M
42664	5	Mario	Pérez	30	7	1946	M
23385	7	Marcos	Rivas	25	11	1947	M
96873	8	Antonio	Munguía	27	6	1942	M
56971	10	Horacio López	Salgado	15	9	1948	M
96177	13	José	Vantolrá	30	3	1943	M
38555	14	Javier	Guzmán	9	1	1945	M
85808	15	Héctor	Pulido	20	12	1942	M
7812	19	Javier	Valdivia	4	12	1941	M
64207	20	Juan Ignacio	Basaguren	21	7	1944	M
18898	22	Francisco	Castrejón	11	6	1947	M
34408	1	Allal	Ben Kassou	11	11	1941	M
93664	2	Abdallah	Lamrani	1	1	1946	M
20578	3	Boujemaa	Benkhrif	30	11	1947	M
48556	4	Moulay	Khanousi	21	6	1939	M
99082	5	Kacem	Slimani	1	7	1948	M
93911	6	Mohammed	Mahroufi	1	1	1947	M
45308	7	Said	Ghandi	16	8	1948	M
55928	8	Driss	Bamous	15	12	1942	M
89897	9	Ahmed	Faras	7	12	1946	M
37859	10	Mohammed	El Filali	9	7	1945	M
85379	11	Maouhoub	Ghazouani	1	1	1946	M
38795	12	Mohammed	Hazzaz	30	11	1944	M
75161	13	Jalili	Fadili	1	1	1940	M
69368	14	Houmane	Jarir	30	11	1944	M
45711	15	Hadi	Dahane	1	1	1946	M
15207	16	Moustapha	Choukri	1	1	1945	M
50217	17	Ahmed	Alaoui	1	1	1949	M
98667	18	Abdelkader	El Khiati	1	1	1945	M
99251	19	Abdelkader	Ouaraghli	1	1	1943	M
15677	1	Luis	Rubiños	31	12	1940	M
30953	2	Eloy	Campos	31	5	1942	M
38349	3	Orlando	de la Torre	21	11	1943	M
76522	4	Héctor	Chumpitaz	12	4	1944	M
80565	5	Nicolás	Fuentes	20	12	1941	M
39336	6	Ramón	Mifflin	5	4	1947	M
19550	7	Roberto	Challe	24	11	1946	M
64457	8	Julio	Baylón	10	12	1947	M
83669	9	Pedro Pablo	León	26	3	1943	M
96979	10	Teófilo	Cubillas	8	3	1949	M
3607	11	Alberto	Gallardo	28	11	1940	M
24515	12	Rubén	Correa	25	7	1941	M
32760	13	Pedro	González	19	5	1943	M
20506	14	José	Fernández	14	2	1939	M
38889	15	Javier	González	11	5	1939	M
53754	16	Félix	Salinas	11	5	1939	M
96893	17	Luis	Cruzado	6	7	1941	M
17992	18	José	del Castillo	1	1	1943	M
17652	19	Eladio	Reyes	8	1	1948	M
49357	20	Hugo	Sotil	18	5	1949	M
84160	21	Jesus	Goyzueta	1	1	1947	M
51451	22	Oswaldo	Ramírez	29	3	1947	M
4931	1	Necula	Răducanu	10	5	1946	M
35798	2	Lajos	Sătmăreanu	21	2	1944	M
53044	3	Nicolae	Lupescu	17	12	1940	M
61942	4	Mihai	Mocanu	24	2	1942	M
98936	5	Cornel	Dinu	2	8	1948	M
65622	6	Dan	Coe	8	9	1941	M
2403	7	Emerich	Dembrovschi	6	10	1945	M
75663	8	Nicolae	Dobrin	26	8	1947	M
51434	9	Florea	Dumitrache	22	5	1948	M
41601	10	Radu	Nunweiller	16	11	1944	M
9236	11	Mircea	Lucescu	29	7	1945	M
52148	12	Mihai	Ivăncescu	22	3	1942	M
37721	13	Augustin	Deleanu	23	8	1944	M
3154	14	Vasile	Gergely	28	10	1941	M
26224	15	Ion	Dumitru	2	1	1950	M
50489	16	Alexandru	Neagu	19	7	1948	M
21011	17	Gheorghe	Tătaru	5	5	1948	M
76074	18	Marin	Tufan	14	10	1942	M
80696	19	Flavius	Domide	11	5	1946	M
15758	20	Nicolae	Pescaru	27	3	1943	M
26945	21	Stere	Adamache	17	8	1941	M
73129	22	Gheorghe	Gornea	2	8	1944	M
99794	1	Leonid	Shmuts	8	10	1948	M
70748	4	Revaz	Dzodzuashvili	15	4	1945	M
17002	5	Vladimir	Kaplichny	26	2	1944	M
52906	6	Evgeny	Lovchev	29	1	1949	M
70408	7	Gennady	Logofet	15	4	1942	M
97724	10	Valery	Zykov	24	2	1944	M
33189	11	Kakhi	Asatiani	1	1	1947	M
79846	12	Nikolay	Kiselyov	29	1	1946	M
50044	14	Vladimir	Muntyan	14	9	1946	M
2102	16	Anatoliy	Byshovets	23	4	1946	M
72049	17	Gennady	Yevriuzhikin	4	2	1944	M
43733	19	Givi	Nodia	2	1	1948	M
59828	20	Anatoliy	Puzach	3	6	1941	M
98262	21	Vitaly	Khmelnitsky	12	6	1943	M
43209	1	Ronnie	Hellström	21	2	1949	M
84013	2	Hans	Selander	15	3	1945	M
15529	3	Kurt	Axelsson	10	11	1941	M
29454	4	Björn	Nordqvist	6	10	1942	M
82719	5	Roland	Grip	1	1	1941	M
22223	6	Tommy	Svensson	4	3	1945	M
86931	7	Bo	Larsson	5	5	1944	M
61735	8	Leif	Eriksson	20	3	1942	M
73517	9	Ove	Kindvall	16	5	1943	M
37575	10	Ove	Grahn	9	5	1943	M
61494	11	Örjan	Persson	27	8	1942	M
12397	12	Sven-Gunnar	Larsson	10	5	1940	M
20172	13	Claes	Cronqvist	15	10	1944	M
2986	14	Krister	Kristensson	25	7	1942	M
71234	15	Leif	Målberg	1	9	1945	M
63446	16	Tomas	Nordahl	24	5	1946	M
37477	17	Ronney	Pettersson	26	4	1940	M
746	18	Tom	Turesson	17	5	1942	M
5872	19	Göran	Nicklasson	20	8	1942	M
48546	20	Jan	Olsson	18	3	1944	M
71589	21	Inge	Ejderstedt	24	12	1946	M
31050	22	Sten	Pålsson	4	12	1945	M
47978	2	Atilio	Ancheta	19	7	1948	M
83747	3	Roberto	Matosas	11	5	1940	M
83931	5	Julio	Montero Castillo	25	4	1944	M
50162	6	Juan	Mujica	22	12	1943	M
40429	10	Ildo	Maneiro	4	8	1947	M
93811	11	Julio	Morales	16	2	1945	M
51832	12	Héctor	Santos	29	10	1944	M
90366	13	Rodolfo	Sandoval	4	10	1948	M
58801	14	Francisco	Cámera	1	1	1944	M
48169	15	Dagoberto	Fontes	6	6	1943	M
51410	17	Rúben	Bareño	23	1	1944	M
95376	18	Alberto	Gómez	10	6	1944	M
2662	19	Oscar	Zubia	8	2	1946	M
8424	21	Julio	Losada	16	6	1950	M
81455	22	Walter	Corbo	2	5	1949	M
69695	7	Berti	Vogts	30	12	1946	M
63982	11	Klaus	Fichtel	19	11	1944	M
72441	13	Gerd	Müller	3	11	1945	M
62529	14	Reinhard	Libuda	10	10	1943	M
12863	17	Hannes	Löhr	5	7	1942	M
9958	19	Peter	Dietrich	6	3	1944	M
89031	21	Manfred	Manglitz	8	3	1940	M
57908	22	Horst	Wolter	8	6	1942	M
53390	1	Daniel	Carnevali	4	12	1946	M
30957	2	Rubén	Ayala	8	1	1950	M
33365	3	Carlos	Babington	20	9	1949	M
26050	4	Agustín	Balbuena	1	9	1945	M
56518	5	Ángel	Bargas	29	10	1946	M
79103	6	Miguel Ángel	Brindisi	8	10	1950	M
37370	7	Jorge	Carrascosa	15	8	1948	M
16804	8	Enrique	Chazarreta	29	7	1947	M
64046	9	Rubén	Glaria	10	3	1948	M
82218	10	Ramón	Heredia	26	2	1951	M
4739	11	René	Houseman	19	7	1953	M
25276	12	Ubaldo	Fillol	21	7	1950	M
35082	13	Mario	Kempes	15	7	1954	M
49585	15	Aldo	Poy	14	9	1945	M
16060	16	Francisco	Sá	25	10	1945	M
63462	17	Carlos	Squeo	4	6	1948	M
68438	18	Roberto	Telch	6	11	1943	M
39768	19	Néstor	Togneri	27	11	1942	M
90840	20	Enrique	Wolff	21	2	1949	M
81341	21	Miguel Ángel	Santoro	27	2	1942	M
82033	22	Héctor	Yazalde	29	5	1946	M
24116	1	Jack	Reilly	27	8	1945	M
14851	2	Doug	Utjesenovic	8	10	1946	M
41457	3	Peter	Wilson	15	9	1947	M
57113	4	Manfred	Schaefer	12	2	1943	M
39161	5	Colin	Curran	21	8	1947	M
6541	6	Ray	Richards	18	5	1946	M
84569	7	Jimmy	Rooney	10	12	1945	M
97283	8	Jimmy	Mackay	19	12	1943	M
68903	9	Johnny	Warren	17	5	1943	M
82355	10	Garry	Manuel	20	2	1950	M
22858	11	Attila	Abonyi	16	8	1946	M
31090	12	Adrian	Alston	6	2	1949	M
71410	13	Peter	Ollerton	20	5	1951	M
41896	14	Max	Tolson	18	7	1945	M
90391	15	Harry	Williams	7	5	1951	M
69601	16	Ivo	Rudic	24	1	1942	M
64841	17	Dave	Harding	14	8	1946	M
19334	18	Johnny	Watkiss	28	3	1941	M
33066	19	Ernie	Campbell	20	10	1949	M
37148	20	Branko	Buljevic	6	9	1947	M
68603	21	Jim	Milisavljevic	15	4	1951	M
29734	22	Allan	Maher	21	7	1950	M
87744	2	Luís	Pereira	21	6	1949	M
89772	3	Marinho	Peres	19	3	1947	M
81415	6	Marinho	Chagas	8	2	1952	M
50358	8	not applicable	Leivinha	11	9	1949	M
73846	9	not applicable	César	17	5	1945	M
60490	12	not applicable	Renato	5	12	1944	M
89117	13	not applicable	Valdomiro	17	2	1946	M
48382	14	not applicable	Nelinho	26	7	1950	M
6277	15	not applicable	Alfredo	18	10	1946	M
7188	17	not applicable	Carpegiani	7	2	1949	M
41064	18	Ademir	da Guia	3	4	1942	M
1779	19	not applicable	Mirandinha	26	2	1952	M
89519	21	not applicable	Dirceu	15	6	1952	M
60866	22	Waldir	Peres	2	2	1951	M
74765	1	Rumyancho	Goranov	17	3	1950	M
97295	2	Ivan	Zafirov	30	12	1947	M
75999	4	Stefko	Velichkov	15	2	1949	M
35917	5	Bozhil	Kolev	20	5	1949	M
74402	7	Voyn	Voynov	7	9	1952	M
95083	9	Atanas	Mihailov	5	7	1949	M
80628	10	Ivan	Stoyanov	20	1	1949	M
4554	11	Georgi	Denev	18	4	1950	M
90799	13	Mladen	Vasilev	29	7	1947	M
68155	14	Kiril	Milanov	17	10	1948	M
66322	15	Pavel	Panov	14	9	1950	M
76230	18	Tsonyo	Vasilev	7	1	1952	M
96963	19	Kiril	Ivkov	21	6	1946	M
77670	20	Krasimir	Borisov	8	4	1950	M
62720	21	Stefan	Staykov	3	10	1949	M
80380	1	Leopoldo	Vallejos	16	7	1944	M
51910	2	Rolando	García	15	12	1942	M
78049	3	Alberto	Quintano	26	4	1946	M
3546	4	Antonio	Arias	9	10	1944	M
23733	6	Juan	Rodríguez	16	1	1944	M
57208	7	Carlos	Caszely	5	7	1950	M
34039	9	Sergio	Ahumada	2	10	1948	M
34664	10	Carlos	Reinoso	7	3	1945	M
54736	11	Leonardo	Véliz	3	9	1945	M
37201	12	Juan	Machuca	7	3	1951	M
4458	13	Rafael	González	24	4	1950	M
73006	14	Alfonso	Lara	27	4	1946	M
36374	15	Mario	Galindo	10	8	1951	M
27772	16	Guillermo	Páez	18	4	1945	M
28298	18	Jorge	Socías	6	10	1951	M
46424	19	Rogelio	Farías	13	8	1949	M
67855	20	Osvaldo	Castro	14	4	1947	M
2104	22	Adolfo	Nef	18	1	1946	M
79032	1	Jürgen	Croy	19	10	1946	M
55761	2	Lothar	Kurbjuweit	6	11	1950	M
18468	3	Bernd	Bransch	24	9	1944	M
72348	4	Konrad	Weise	17	8	1951	M
88482	5	Joachim	Fritsche	28	10	1951	M
34021	6	Rüdiger	Schnuphase	23	1	1954	M
24093	7	Jürgen	Pommerenke	22	1	1953	M
8298	8	Wolfram	Löwe	14	5	1945	M
62195	9	Peter	Ducke	14	10	1941	M
87788	10	Hans-Jürgen	Kreische	19	7	1947	M
91963	11	Joachim	Streich	13	4	1951	M
57266	12	Siegmar	Wätzlich	16	11	1947	M
73521	13	Reinhard	Lauck	16	9	1946	M
27040	14	Jürgen	Sparwasser	4	6	1948	M
53970	15	Eberhard	Vogel	8	4	1943	M
46189	16	Harald	Irmscher	12	2	1946	M
73193	17	Erich	Hamann	27	11	1944	M
12102	18	Gerd	Kische	23	10	1951	M
4924	19	Wolfgang	Seguin	14	9	1945	M
57624	20	Martin	Hoffmann	22	3	1955	M
54611	21	Wolfgang	Blochwitz	8	2	1941	M
1760	22	Werner	Friese	30	3	1946	M
46307	1	Henri	Françillon	26	5	1946	M
93412	2	Wilfried	Louis	25	10	1949	M
47461	3	Arsène	Auguste	3	2	1951	M
67450	4	Fritz	André	18	9	1946	M
71319	5	Serge	Ducosté	4	2	1944	M
28084	6	Pierre	Bayonne	11	6	1949	M
40069	7	Philippe	Vorbe	14	9	1947	M
83389	8	Jean-Claude	Désir	8	8	1946	M
54786	9	Eddy	Antoine	27	8	1949	M
39155	10	Guy	François	18	9	1947	M
58000	11	Guy	Saint-Vil	21	10	1942	M
13619	12	Ernst	Jean-Joseph	11	6	1948	M
11430	13	Serge	Racine	9	10	1951	M
14414	14	Wilner	Nazaire	30	3	1950	M
28638	15	Roger	Saint-Vil	8	12	1949	M
16092	16	Fritz	Leandré	13	3	1948	M
52149	17	Joseph-Marion	Leandré	9	5	1945	M
50623	18	Claude	Barthélemy	9	5	1945	M
19426	19	Jean-Herbert	Austin	23	2	1950	M
32958	20	Emmanuel	Sanon	25	6	1951	M
87822	21	Wilner	Piquant	12	10	1949	M
42054	22	Gérard	Joseph	22	10	1949	M
39619	2	Luciano	Spinosi	9	5	1950	M
12030	4	Romeo	Benetti	20	10	1945	M
72137	5	Francesco	Morini	12	8	1944	M
93703	8	Fabio	Capello	18	6	1946	M
74017	9	Giorgio	Chinaglia	24	1	1947	M
31389	13	Giuseppe	Sabadini	26	3	1949	M
83005	14	Mauro	Bellugi	7	2	1950	M
97066	15	Giuseppe	Wilson	27	10	1945	M
58264	17	Luciano	Re Cecconi	1	12	1948	M
44349	18	Franco	Causio	1	2	1949	M
32265	19	Pietro	Anastasi	7	4	1948	M
29600	21	Paolo	Pulici	27	4	1950	M
65172	22	Luciano	Castellini	12	12	1945	M
76357	1	Ruud	Geels	28	7	1948	M
1582	2	Arie	Haan	16	11	1948	M
65100	3	Willem	van Hanegem	20	2	1944	M
29733	4	Kees	van Ierssel	6	12	1945	M
74745	5	Rinus	Israël	19	3	1942	M
89311	6	Wim	Jansen	28	10	1946	M
43188	7	Theo	de Jong	11	8	1947	M
12372	8	Jan	Jongbloed	25	11	1940	M
84295	9	Piet	Keizer	14	6	1943	M
25337	10	René	van de Kerkhof	16	9	1951	M
48712	11	Willy	van de Kerkhof	16	9	1951	M
31830	12	Ruud	Krol	24	3	1949	M
16991	13	Johan	Neeskens	15	9	1951	M
50564	14	Johan	Cruyff	25	4	1947	M
63266	15	Rob	Rensenbrink	3	7	1947	M
89554	16	Johnny	Rep	25	11	1951	M
48827	17	Wim	Rijsbergen	18	1	1952	M
35622	18	Piet	Schrijvers	15	12	1946	M
36	19	Pleun	Strik	27	5	1944	M
45370	20	Wim	Suurbier	16	1	1945	M
89818	21	Eddy	Treijtel	28	5	1946	M
44945	22	Harry	Vos	4	9	1946	M
96371	1	Andrzej	Fischer	15	1	1952	M
6667	2	Jan	Tomaszewski	9	1	1948	M
62487	3	Zygmunt	Kalinowski	2	5	1949	M
89521	4	Antoni	Szymanowski	13	1	1951	M
17846	5	Zbigniew	Gut	17	4	1949	M
95634	6	Jerzy	Gorgoń	18	7	1949	M
57366	7	Henryk	Wieczorek	14	12	1949	M
90440	8	Mirosław	Bulzacki	23	10	1951	M
48883	9	Władysław	Żmuda	6	6	1954	M
39234	10	Adam	Musiał	18	12	1948	M
7479	11	Lesław	Ćmikiewicz	25	8	1948	M
29548	12	Kazimierz	Deyna	23	10	1947	M
97548	13	Henryk	Kasperczak	10	7	1946	M
65840	14	Zygmunt	Maszczyk	3	5	1945	M
45208	15	Roman	Jakóbczak	26	2	1946	M
21597	16	Grzegorz	Lato	8	4	1950	M
92867	17	Andrzej	Szarmach	3	10	1950	M
20188	18	Robert	Gadocha	10	1	1946	M
58729	19	Jan	Domarski	28	10	1946	M
28931	20	Zdzisław	Kapka	7	12	1954	M
26520	21	Kazimierz	Kmiecik	19	9	1951	M
69383	22	Marek	Kusto	29	4	1954	M
30434	1	David	Harvey	7	2	1948	M
88006	2	Sandy	Jardine	31	12	1948	M
66125	3	Danny	McGrain	1	5	1950	M
63058	4	Billy	Bremner	9	12	1942	M
87058	5	Jim	Holton	11	4	1951	M
36988	6	John	Blackley	12	5	1948	M
93687	7	Jimmy	Johnstone	30	9	1944	M
68584	8	Kenny	Dalglish	4	3	1951	M
22480	9	Joe	Jordan	15	12	1951	M
47050	10	David	Hay	29	1	1948	M
21810	11	Peter	Lorimer	14	12	1946	M
72460	12	Thomson	Allan	5	10	1946	M
62568	13	Jim	Stewart	9	3	1954	M
98422	14	Martin	Buchan	6	3	1949	M
78929	15	Peter	Cormack	17	7	1946	M
14033	16	Willie	Donachie	5	10	1951	M
78336	17	Donald	Ford	25	10	1944	M
27901	18	Tommy	Hutchison	22	9	1947	M
22762	19	Denis	Law	24	2	1940	M
87723	20	Willie	Morgan	2	10	1944	M
54370	21	Gordon	McQueen	26	6	1952	M
24731	22	Erich	Schaedler	6	8	1949	M
96792	2	Jan	Olsson	30	3	1942	M
37942	3	Kent	Karlsson	25	11	1945	M
90911	5	Björn	Andersson	20	7	1951	M
52989	8	Conny	Torstensson	28	8	1949	M
39318	10	Ralf	Edström	7	10	1952	M
94413	11	Roland	Sandberg	16	12	1946	M
88425	14	Staffan	Tapper	10	7	1948	M
2323	15	Benno	Magnusson	4	2	1953	M
16755	17	Göran	Hagberg	8	11	1947	M
33030	18	Jörgen	Augustsson	28	10	1952	M
12173	20	Sven	Lindman	19	4	1942	M
30429	22	Thomas	Ahlström	17	7	1952	M
50198	2	Baudilio	Jáuregui	9	7	1945	M
32274	3	Juan Carlos	Masnik	2	3	1943	M
46047	6	Ricardo	Pavoni	8	7	1943	M
36986	9	Fernando	Morena	2	2	1952	M
61660	11	Rubén	Corbo	20	1	1952	M
62134	13	Gustavo	de Simone	23	4	1948	M
13110	14	Luis	Garisto	3	12	1945	M
32102	15	Mario	González	27	5	1950	M
35067	16	Alberto	Cardaccio	26	8	1949	M
85474	17	Julio César	Jiménez	27	8	1954	M
11707	18	Walter	Mantegazza	17	6	1952	M
82387	19	Denis	Milar	20	6	1952	M
85775	20	Juan	Silva	5	8	1948	M
19953	21	José	Gómez	23	10	1949	M
85729	22	Gustavo	Fernández	16	2	1952	M
48686	3	Paul	Breitner	5	9	1951	M
66174	4	Hans-Georg	Schwarzenbeck	3	4	1948	M
89257	7	Herbert	Wimmer	9	11	1944	M
44313	8	Bernhard	Cullmann	1	11	1949	M
66405	10	Günter	Netzer	14	9	1944	M
79006	11	Jupp	Heynckes	9	5	1945	M
92173	14	Uli	Hoeneß	5	1	1952	M
15681	15	Heinz	Flohe	28	1	1948	M
41102	16	Rainer	Bonhof	29	3	1952	M
35602	17	Bernd	Hölzenbein	9	3	1946	M
89218	18	Dieter	Herzog	15	7	1946	M
25938	19	Jupp	Kapellmann	19	12	1949	M
48661	20	Helmut	Kremers	24	3	1949	M
7141	21	Norbert	Nigbur	8	5	1948	M
44327	22	Wolfgang	Kleff	16	11	1946	M
84648	1	Enver	Marić	23	4	1948	M
47694	2	Ivan	Buljan	11	12	1949	M
262	3	Enver	Hadžiabdić	6	11	1945	M
2400	4	Dražen	Mužinić	25	1	1953	M
20553	5	Josip	Katalinski	12	5	1948	M
29556	6	Vladislav	Bogićević	7	11	1950	M
46434	7	Ilija	Petković	22	9	1945	M
26214	8	Branko	Oblak	27	5	1947	M
28747	9	Ivica	Šurjak	23	3	1953	M
67954	10	Jovan	Aćimović	21	6	1948	M
88088	11	Dragan	Džajić	30	5	1946	M
27514	12	Jurica	Jerković	25	2	1950	M
62762	13	Miroslav	Pavlović	23	10	1942	M
19642	14	Luka	Peruzović	26	2	1952	M
60845	15	Kiril	Dojčinovski	17	10	1943	M
52104	16	Franjo	Vladić	19	10	1951	M
23309	17	Danilo	Popivoda	1	5	1947	M
80725	18	Stanislav	Karasi	8	11	1946	M
74389	19	Dušan	Bajević	10	12	1948	M
43672	20	Vladimir	Petrović	1	7	1955	M
18421	21	Ognjen	Petrović	2	1	1948	M
20595	22	Rizah	Mešković	10	8	1947	M
49497	1	Kazadi	Mwamba	6	3	1947	M
99200	2	Mwepu	Ilunga	22	8	1949	M
44782	3	Mwanza	Mukombo	17	12	1945	M
68390	4	Bwanga	Tshimen	4	1	1949	M
69624	5	Lobilo	Boba	10	4	1950	M
1597	6	Kilasu	Massamba	22	12	1950	M
92929	7	Martin Kamunda	Tshinabu	8	5	1946	M
57731	8	Mana	Mamuwene	10	10	1947	M
87506	9	Jean	Kembo Uba-Kembo	27	12	1947	M
49087	10	Kidumu	Mantantu	17	11	1946	M
67711	11	Kabasu	Babo	4	3	1950	M
71914	12	Tubilandu	Ndimbi	15	3	1948	M
88955	13	Ndaye	Mulamba	4	11	1948	M
27837	14	Mayanga	Maku	31	10	1948	M
38620	15	Kibonge	Mafu	12	2	1945	M
739	16	Mwape	Mialo	30	12	1951	M
71906	17	Kafula	Ngoie	11	11	1945	M
20897	18	Mavuba	Mafuila	15	12	1949	M
28534	19	Mbungu	Ekofa	24	11	1948	M
56615	20	Jean Kalala	N'Tumba	7	1	1949	M
11236	21	Kakoko	Etepe	22	11	1950	M
10863	22	Kalambay	Otepa	12	11	1948	M
44317	1	Norberto	Alonso	4	1	1953	M
66254	2	Osvaldo	Ardiles	3	8	1952	M
45593	3	Héctor	Baley	16	11	1950	M
61157	4	Daniel	Bertoni	14	3	1955	M
99593	6	Américo	Gallego	25	4	1955	M
3905	7	Luis	Galván	24	2	1948	M
21190	8	Rubén	Galván	7	4	1952	M
30336	11	Daniel	Killer	21	12	1949	M
23168	12	Omar	Larrosa	18	11	1947	M
66065	13	Ricardo	La Volpe	6	2	1952	M
26640	14	Leopoldo	Luque	3	5	1949	M
6976	15	Jorge	Olguín	17	5	1952	M
34830	16	Oscar	Ortiz	8	4	1953	M
45194	17	Miguel	Oviedo	12	10	1950	M
1736	18	Rubén	Pagnanini	31	1	1949	M
80376	19	Daniel	Passarella	25	5	1953	M
54098	20	Alberto	Tarantini	3	12	1955	M
62351	21	José Daniel	Valencia	3	10	1955	M
12477	22	Ricardo	Villa	18	8	1952	M
62318	1	Friedrich	Koncilia	25	2	1948	M
47233	2	Robert	Sara	9	6	1946	M
61365	3	Erich	Obermayer	23	1	1953	M
49343	4	Gerhard	Breitenberger	14	10	1954	M
92720	5	Bruno	Pezzey	3	2	1955	M
31109	6	Roland	Hattenberger	7	12	1948	M
68078	7	Josef	Hickersberger	27	4	1948	M
3451	8	Herbert	Prohaska	8	8	1955	M
52271	9	Hans	Krankl	14	2	1953	M
25569	10	Wilhelm	Kreuz	29	5	1949	M
90221	11	Kurt	Jara	14	10	1950	M
15636	12	Eduard	Krieger	16	12	1946	M
73149	13	Günther	Happich	28	1	1952	M
80182	14	Heinrich	Strasser	26	10	1948	M
5699	15	Heribert	Weber	28	6	1955	M
27925	16	Peter	Persidis	8	3	1947	M
75962	17	Franz	Oberacher	24	3	1954	M
99989	18	Walter	Schachner	1	2	1957	M
82174	19	Hans	Pirkner	25	3	1946	M
82507	20	Ernst	Baumeister	22	1	1957	M
40884	21	Erwin	Fuchsbichler	27	3	1952	M
28170	22	Hubert	Baumgartner	25	2	1955	M
52658	2	not applicable	Toninho	7	6	1948	M
69644	3	not applicable	Oscar	20	6	1954	M
54171	4	not applicable	Amaral	25	12	1954	M
22554	5	Toninho	Cerezo	21	4	1955	M
12950	6	not applicable	Edinho	5	6	1955	M
4940	7	not applicable	Zé Sérgio	8	3	1957	M
37483	8	not applicable	Zico	3	3	1953	M
84320	9	not applicable	Reinaldo	11	1	1957	M
43781	12	not applicable	Carlos	4	3	1956	M
99390	14	not applicable	Abel	1	9	1952	M
70909	15	not applicable	Polozzi	1	10	1955	M
67433	16	Rodrigues	Neto	6	12	1949	M
99975	17	not applicable	Batista	8	3	1955	M
34545	18	not applicable	Gil	24	12	1950	M
23407	19	Jorge	Mendonça	6	6	1954	M
86942	20	Roberto	Dinamite	13	4	1954	M
53581	21	not applicable	Chicão	30	1	1949	M
41870	1	Dominique	Baratelli	26	12	1947	M
12738	2	Patrick	Battiston	12	3	1957	M
3719	3	Maxime	Bossis	26	6	1955	M
34605	4	Gérard	Janvion	21	8	1953	M
86043	5	François	Bracci	3	11	1951	M
90883	6	Christian	Lopez	15	3	1953	M
56255	7	Patrice	Rio	15	8	1948	M
54040	8	Marius	Trésor	15	1	1950	M
19199	9	Dominique	Bathenay	13	2	1954	M
65887	10	Jean-Marc	Guillou	20	12	1945	M
48925	11	Henri	Michel	28	10	1947	M
50374	12	Claude	Papi	16	4	1949	M
54760	13	Jean	Petit	25	9	1949	M
27315	14	Marc	Berdoll	6	4	1953	M
8939	15	Michel	Platini	21	6	1955	M
83674	16	Christian	Dalger	19	12	1949	M
16067	17	Bernard	Lacombe	15	8	1952	M
99991	18	Dominique	Rocheteau	14	1	1955	M
74565	19	Didier	Six	21	8	1954	M
67442	20	Olivier	Rouyer	1	12	1955	M
32988	21	Jean-Paul	Bertrand-Demanes	23	5	1952	M
80046	22	Dominique	Dropsy	9	12	1951	M
64266	1	Sándor	Gujdár	8	11	1951	M
56063	2	Péter	Török	18	4	1951	M
99164	3	István	Kocsis	6	10	1949	M
42012	4	József	Tóth	2	12	1951	M
12183	5	Sándor	Zombori	31	10	1951	M
36123	6	Zoltán	Kereki	13	7	1953	M
99185	7	László	Fazekas	15	10	1947	M
34326	8	Tibor	Nyilasi	18	1	1955	M
86777	9	András	Törőcsik	1	5	1955	M
45243	10	Sándor	Pintér	18	7	1950	M
13770	11	Béla	Várady	12	4	1953	M
70353	12	Győző	Martos	15	12	1949	M
17566	13	Károly	Csapó	23	2	1952	M
53099	14	László	Bálint	1	2	1948	M
2094	15	Tibor	Rab	2	10	1955	M
88526	16	István	Halász	12	10	1951	M
77765	17	László	Pusztai	1	3	1946	M
15153	18	László	Nagy	21	10	1949	M
5262	19	András	Tóth	5	9	1949	M
72757	20	Ferenc	Fülöp	22	2	1955	M
67438	21	Ferenc	Mészáros	11	4	1950	M
53278	22	László	Kovács	24	4	1951	M
47243	1	Nasser	Hejazi	14	12	1949	M
76170	2	Iraj	Danaeifard	19	3	1951	M
77051	3	Behtash	Fariba	11	2	1955	M
64960	4	Majid	Bishkar	6	8	1956	M
85841	5	Javad	Allahverdi	16	7	1954	M
36227	6	Hassan	Nayebagha	17	9	1950	M
81360	7	Ali	Parvin	12	10	1946	M
64031	8	Ebrahim	Ghasempour	24	8	1956	M
64311	9	Mohammad	Sadeghi	17	3	1951	M
36867	10	Hassan	Roshan	2	6	1955	M
90846	11	Ali Reza	Ghesghayan	27	2	1954	M
4692	12	Bahram	Mavaddat	30	1	1950	M
76892	13	Hamid	Majd Teymouri	3	6	1953	M
33083	14	Hassan	Nazari	19	8	1955	M
61698	15	Andranik	Eskandarian	31	12	1951	M
88492	16	Nasser	Nouraei	9	7	1956	M
60654	17	Ghafour	Jahani	18	6	1950	M
14915	18	Hossein	Faraki	19	4	1956	M
70253	19	Ali	Shojaei	23	3	1953	M
98081	20	Nasrollah	Abdollahi	2	9	1951	M
25070	21	Hossein	Kazerani	13	4	1947	M
29913	22	Rasoul	Korbekandi	27	1	1953	M
3775	3	Antonio	Cabrini	8	10	1957	M
5902	4	Antonello	Cuccureddu	4	10	1949	M
21248	5	Claudio	Gentile	27	9	1953	M
84137	6	Aldo	Maldera	14	10	1953	M
78456	7	Lionello	Manfredonia	27	11	1956	M
99788	8	Gaetano	Scirea	25	5	1953	M
88467	9	Giancarlo	Antognoni	1	4	1954	M
34868	11	Eraldo	Pecci	12	4	1955	M
37637	12	Paolo	Conti	1	4	1950	M
39505	13	Patrizio	Sala	16	6	1955	M
93788	14	Marco	Tardelli	24	9	1954	M
17293	15	Renato	Zaccarelli	18	1	1951	M
80851	17	Claudio	Sala	8	9	1947	M
57787	18	Roberto	Bettega	27	12	1950	M
16875	19	Francesco	Graziani	16	12	1952	M
91717	21	Paolo	Rossi	23	9	1956	M
76506	22	Ivano	Bordon	13	4	1951	M
7985	1	José Pilar	Reyes	12	10	1955	M
86324	2	Manuel	Nájera	20	12	1952	M
4060	3	Alfredo	Tena	21	11	1956	M
4466	4	Eduardo	Ramos	8	11	1949	M
84173	5	Arturo	Vázquez Ayala	26	6	1949	M
55869	6	Guillermo	Mendizábal	8	10	1954	M
8713	7	Antonio	de la Torre	21	9	1951	M
3980	8	Enrique López	Zarza	25	10	1957	M
64532	9	Víctor	Rangel	11	3	1957	M
10248	10	Cristóbal	Ortega	25	7	1956	M
26316	11	Hugo	Sánchez	11	7	1958	M
64464	12	Jesús	Martínez	7	6	1952	M
67584	13	Rigoberto	Cisneros	15	8	1953	M
46352	14	Carlos	Gómez	16	8	1952	M
42842	15	Ignacio	Flores Ocaranza	31	7	1953	M
25743	16	Javier	Cárdenas	8	12	1952	M
69029	17	Leonardo	Cuéllar	14	1	1952	M
21068	18	Gerardo	Lugo	13	3	1955	M
49253	19	Hugo René	Rodríguez	14	3	1959	M
19851	20	Mario	Medina	2	9	1952	M
52419	21	Raúl	Isiordia	22	12	1952	M
50233	22	Pedro	Soto	22	10	1952	M
3270	2	Jan	Poortvliet	21	9	1955	M
60031	3	Dick	Schoenaker	30	11	1952	M
37179	4	Adrie	van Kraay	1	8	1953	M
46710	7	Piet	Wildschut	25	10	1957	M
55099	14	Johan	Boskamp	21	10	1948	M
23888	15	Hugo	Hovenkamp	5	10	1950	M
48111	18	Dick	Nanninga	17	1	1949	M
60714	19	Pim	Doesburg	28	10	1943	M
91947	21	Harry	Lubse	23	9	1951	M
82670	22	Ernie	Brandts	3	2	1956	M
28179	1	Ottorino	Sartor	18	9	1945	M
32834	2	Jaime	Duarte	27	2	1955	M
32373	3	Rodolfo	Manzo	5	6	1949	M
93346	5	Rubén Toribio	Díaz	17	4	1952	M
72529	6	José	Velásquez	4	6	1952	M
91524	7	Juan	Muñante	12	6	1948	M
23639	8	César	Cueto	16	6	1952	M
94008	9	Percy	Rojas	16	9	1949	M
50099	11	Carlos Juan	Oblitas	16	2	1951	M
48921	12	Roberto	Mosquera	21	6	1956	M
3944	13	Juan	Cáceres	27	12	1949	M
67187	14	José	Navarro	24	9	1948	M
85374	15	Germán	Leguía	2	1	1954	M
44786	16	Raúl	Gorriti	10	10	1956	M
94706	17	Alfredo	Quesada	22	9	1949	M
62666	18	Ernesto	Labarthe	2	6	1956	M
42136	19	Guillermo	La Rosa	6	6	1952	M
7978	21	Ramón	Quiroga	23	7	1950	M
28828	22	Roberto	Rojas	26	10	1955	M
60895	2	Włodzimierz	Mazur	18	4	1954	M
56499	3	Henryk	Maculewicz	24	4	1950	M
42824	5	Adam	Nawałka	23	10	1957	M
18317	7	Andrzej	Iwan	10	11	1959	M
32819	10	Wojciech	Rudy	24	10	1952	M
37521	11	Bohdan	Masztaler	19	9	1949	M
15890	13	Janusz	Kupcewicz	9	12	1955	M
99151	14	Mirosław	Justek	23	9	1948	M
3652	18	Zbigniew	Boniek	3	3	1956	M
67962	19	Włodzimierz	Lubański	28	2	1947	M
22126	20	Roman	Wójcicki	8	1	1958	M
9868	21	Zygmunt	Kukla	21	1	1948	M
19443	22	Zdzisław	Kostrzewa	26	10	1955	M
5695	1	Alan	Rough	25	11	1951	M
93612	6	Bruce	Rioch	6	9	1947	M
58552	7	Don	Masson	26	8	1946	M
57616	10	Asa	Hartford	24	10	1950	M
73968	11	Willie	Johnston	19	12	1946	M
32668	12	Jim	Blyth	2	2	1955	M
53235	13	Stuart	Kennedy	31	5	1953	M
23439	14	Tom	Forsyth	23	1	1949	M
16479	15	Archie	Gemmill	24	3	1947	M
35089	16	Lou	Macari	7	6	1949	M
48230	17	Derek	Johnstone	4	11	1953	M
91562	18	Graeme	Souness	6	5	1953	M
96391	19	John	Robertson	20	1	1953	M
3406	20	Bobby	Clark	26	9	1945	M
57585	21	Joe	Harper	11	1	1948	M
94977	22	Kenny	Burns	23	9	1953	M
84380	1	Luis	Arconada	26	6	1954	M
26973	2	Antonio	de la Cruz	7	5	1947	M
29981	3	Francisco Javier	Uría	1	2	1950	M
57837	4	Juan Manuel	Asensi	23	9	1949	M
90350	5	not applicable	Migueli	19	12	1951	M
70869	6	Antonio	Biosca	8	12	1948	M
40352	7	not applicable	Dani	28	6	1951	M
3571	8	not applicable	Juanito	10	11	1954	M
99707	9	not applicable	Quini	23	9	1949	M
39440	10	not applicable	Santillana	23	8	1952	M
28881	11	Julio	Cardeñosa	27	10	1949	M
12922	12	Antonio	Guzmán	2	12	1953	M
23912	13	Miguel	Ángel	24	12	1947	M
15195	14	Eugenio	Leal	13	5	1953	M
87767	15	not applicable	Marañón	23	7	1948	M
40419	16	Antonio	Olmo	18	1	1954	M
50273	17	not applicable	Marcelino	13	8	1955	M
78126	19	Carles	Rexach	13	1	1947	M
38692	20	Rubén	Cano	5	2	1951	M
26030	21	Isidoro	San José	27	10	1955	M
44005	22	not applicable	Urruti	17	2	1952	M
59590	2	Hasse	Borg	4	8	1953	M
60570	3	Roy	Andersson	2	8	1949	M
52124	5	Ingemar	Erlandsson	16	11	1957	M
69553	7	Anders	Linderoth	21	3	1950	M
891	9	Lennart	Larsson	9	7	1953	M
61240	10	Thomas	Sjöberg	6	7	1952	M
3989	11	Benny	Wendt	4	11	1950	M
65696	13	Magnus	Andersson	23	4	1958	M
91705	14	Ronald	Åhman	31	1	1957	M
55852	15	Torbjörn	Nilsson	9	7	1954	M
91463	17	Jan	Möller	17	9	1953	M
6774	18	Olle	Nordin	23	11	1949	M
12765	20	Roland	Andersson	28	3	1950	M
35750	21	Sanny	Åslund	29	8	1952	M
25714	1	Sadok	Sassi	15	11	1945	M
32712	2	Mokhtar	Dhouib	23	3	1952	M
10069	3	Ali	Kaabi	15	11	1953	M
82486	4	Khaled	Gasmi	8	4	1953	M
71287	5	Mohsen	Labidi	15	1	1954	M
66055	6	Néjib	Ghommidh	12	3	1953	M
94864	7	Témime	Lahzami	1	1	1949	M
44105	8	Hamadi	Agrebi	20	3	1951	M
47488	9	Mohamed	Akid	5	7	1949	M
12467	10	Tarak	Dhiab	15	7	1954	M
25130	11	Abderraouf	Ben Aziza	23	9	1953	M
36542	12	Khemais	Labidi	30	8	1950	M
32146	13	Néjib	Limam	12	6	1953	M
50864	14	Slah	Karoui	11	9	1951	M
1949	15	Mohamed	Ben Mouza	5	4	1954	M
23179	16	Ohman	Chehaibi	23	12	1954	M
74931	17	Ridha	El Louze	27	4	1953	M
43535	18	Kamel	Chebli	9	3	1954	M
78107	19	Mokhtar	Hasni	19	3	1952	M
16979	20	Amor	Jebali	24	12	1956	M
72733	21	Lamine	Ben Aziza	10	11	1952	M
99636	22	Mokhtar	Naili	3	9	1953	M
55894	3	Bernard	Dietz	22	3	1948	M
47205	4	Rolf	Rüssmann	13	10	1950	M
68969	5	Manfred	Kaltz	6	1	1953	M
64134	7	Rüdiger	Abramczik	18	2	1956	M
3391	8	Herbert	Zimmermann	1	7	1954	M
52461	9	Klaus	Fischer	27	12	1949	M
59574	11	Karl-Heinz	Rummenigge	25	9	1955	M
11877	13	Harald	Konopka	18	11	1952	M
34993	14	Dieter	Müller	1	4	1954	M
20874	15	Erich	Beer	9	12	1946	M
71765	18	Gerd	Zewe	13	6	1950	M
85977	19	Ronald	Worm	7	10	1953	M
95747	20	Hansi	Müller	27	7	1957	M
39513	21	Rudolf	Kargus	15	8	1952	M
96776	22	Dieter	Burdenski	26	11	1950	M
73371	1	Mehdi	Cerbah	3	4	1953	M
88535	2	Mahmoud	Guendouz	24	2	1953	M
21849	3	Mustafa	Kouici	16	4	1954	M
97960	4	Nourredine	Kourichi	12	4	1954	M
73411	5	Chaabane	Merzekane	8	3	1959	M
12808	6	Ali	Bencheikh	9	1	1955	M
40338	7	Salah	Assad	13	3	1958	M
48327	8	Ali	Fergani	21	9	1952	M
68346	9	Tedj	Bensaoula	1	12	1954	M
59774	10	Lakhdar	Belloumi	29	12	1958	M
45774	11	Rabah	Madjer	15	12	1958	M
71313	12	Salah	Larbes	16	9	1952	M
70419	13	Hocine	Yahi	25	4	1960	M
42885	14	Djamel	Zidane	28	4	1955	M
75422	15	Mustapha	Dahleb	8	2	1952	M
63564	16	Faouzi	Mansouri	17	1	1956	M
40564	17	Abdelkader	Horr	10	11	1953	M
16403	18	Karim	Maroc	5	3	1958	M
13314	19	Djamel	Tlemçani	16	4	1955	M
99212	20	Abdelmajid	Bourebbou	16	3	1951	M
15801	21	Mourad	Amara	19	2	1959	M
77356	22	Yacine	Bentalaa	24	9	1955	M
99392	3	Juan	Barbas	23	8	1959	M
10969	5	Gabriel	Calderón	7	2	1960	M
78111	6	Ramón	Díaz	29	8	1959	M
80404	10	Diego	Maradona	30	10	1960	M
79724	12	Patricio	Hernández	16	8	1956	M
46907	13	Julio	Olarticoechea	18	10	1958	M
15637	16	Nery	Pumpido	30	7	1957	M
33159	17	Santiago	Santamaría	22	8	1952	M
29420	19	Enzo	Trossero	23	5	1953	M
2464	20	Jorge	Valdano	4	10	1955	M
26142	22	José	Van Tuyne	13	12	1954	M
77455	2	Bernd	Krauss	8	5	1957	M
32042	4	Josef	Degeorgi	19	1	1960	M
43037	10	Reinhold	Hintermaier	14	2	1956	M
96650	12	Anton	Pichler	4	10	1955	M
96142	13	Max	Hagmayr	16	11	1956	M
6318	15	Johann	Dihanich	24	10	1958	M
84133	16	Gerald	Messlender	1	10	1961	M
41829	17	Johann	Pregesbauer	9	6	1955	M
64028	18	Gernot	Jurtin	9	9	1955	M
13147	20	Kurt	Welzl	6	11	1954	M
7810	21	Herbert	Feurer	14	1	1954	M
29893	22	Klaus	Lindenberger	28	5	1957	M
84816	1	Jean-Marie	Pfaff	4	12	1953	M
73390	2	Eric	Gerets	18	5	1954	M
7663	3	Luc	Millecamps	10	9	1951	M
86900	4	Walter	Meeuws	11	7	1951	M
88903	5	Michel	Renquin	3	11	1955	M
26401	6	Franky	Vercauteren	28	10	1956	M
53789	7	Jos	Daerden	26	11	1954	M
6736	9	Erwin	Vandenbergh	26	1	1959	M
94036	10	Ludo	Coeck	25	9	1955	M
25456	11	Jan	Ceulemans	28	2	1957	M
77440	12	Theo	Custers	10	8	1950	M
43941	13	François	Van Der Elst	1	12	1954	M
53153	14	Marc	Baecke	24	7	1956	M
79995	15	Maurits	De Schrijver	26	6	1951	M
47416	16	Gerard	Plessers	30	3	1959	M
17433	17	René	Verheyen	20	3	1952	M
87975	18	Raymond	Mommens	27	12	1958	M
52742	19	Marc	Millecamps	9	10	1950	M
7477	20	Guy	Vandersmissen	25	12	1957	M
88070	21	Alexandre	Czerniatynski	28	7	1960	M
38187	22	Jacky	Munaron	8	9	1956	M
65003	2	not applicable	Leandro	17	3	1959	M
45267	4	not applicable	Luizinho	22	10	1958	M
83096	6	not applicable	Júnior	29	6	1954	M
6098	7	Paulo	Isidoro	3	8	1953	M
78605	8	not applicable	Sócrates	19	2	1954	M
20664	9	not applicable	Serginho	23	12	1953	M
39132	11	not applicable	Éder	25	5	1957	M
49168	12	Paulo	Sérgio	24	7	1954	M
71619	13	not applicable	Edevaldo	28	1	1958	M
70038	14	not applicable	Juninho	29	8	1958	M
35736	15	not applicable	Falcão	16	10	1953	M
66932	17	not applicable	Pedrinho	22	10	1957	M
56757	19	not applicable	Renato	21	2	1957	M
95667	1	Thomas	N'Kono	20	7	1956	M
73034	2	Michel	Kaham	1	6	1952	M
96632	3	Edmond	Enoka	17	12	1955	M
59682	4	René	N'Djeya	9	10	1953	M
66008	5	Elie	Onana	13	10	1951	M
44016	6	Emmanuel	Kundé	15	7	1956	M
11469	7	Ephrem	M'Bom	18	7	1954	M
32771	8	Grégoire	M'Bida	27	1	1955	M
58080	9	Roger	Milla	20	5	1952	M
34300	10	Jean-Pierre	Tokoto	26	1	1948	M
59315	11	Charles	Toubé	22	1	1958	M
17774	12	Joseph-Antoine	Bell	8	10	1954	M
93565	13	Paul	Bahoken	7	7	1955	M
2805	14	Théophile	Abega	9	7	1954	M
72682	15	François	N'Doumbé	30	1	1954	M
18610	16	Ibrahim	Aoudou	23	8	1955	M
33634	17	Joseph	Kamga	17	8	1953	M
41427	18	Jacques	N'Guea	8	11	1955	M
52069	19	Joseph	Enanga	28	8	1958	M
39692	20	Oscar	Eyobo	23	10	1961	M
93395	21	Ernest	Ebongué	15	5	1962	M
11668	22	Simon	Tchobang	31	8	1951	M
5974	1	Oscar	Wirth	5	11	1955	M
93218	2	Lizardo	Garrido	25	8	1957	M
15628	3	René	Valenzuela	20	4	1955	M
33323	4	Vladimir	Bigorra	9	8	1954	M
26922	6	Rodolfo	Dubó	11	9	1953	M
31736	7	Eduardo	Bonvallet	13	1	1955	M
86201	8	Carlos	Rivas	24	5	1953	M
43905	9	Juan Carlos	Letelier	20	5	1959	M
64288	10	Mario	Soto	10	7	1950	M
56491	11	Gustavo	Moscoso	10	8	1955	M
2230	12	Marco	Cornez	15	10	1957	M
74243	14	Raúl	Ormeño	21	6	1958	M
81864	15	Patricio	Yáñez	20	1	1961	M
12252	16	Manuel	Rojas	13	6	1954	M
12971	17	Oscar	Rojas	15	11	1958	M
95822	19	Enzo	Escobar	10	11	1951	M
71032	20	Miguel Ángel	Neira	9	10	1952	M
3126	21	Miguel Ángel	Gamboa	21	6	1951	M
10055	22	Mario	Osbén	14	7	1950	M
10247	1	Stanislav	Seman	8	8	1952	M
58761	2	František	Jakubec	12	4	1956	M
53399	3	Jan	Fiala	19	5	1956	M
28511	4	Ladislav	Jurkemik	20	7	1953	M
55121	5	Jozef	Barmoš	28	8	1954	M
62199	6	Rostislav	Vojáček	23	2	1949	M
40071	7	Ján	Kozák	17	4	1954	M
19209	8	Antonín	Panenka	2	12	1948	M
95927	9	Ladislav	Vízek	22	1	1955	M
59697	10	Tomáš	Kříž	17	3	1959	M
12019	11	Zdeněk	Nehoda	9	5	1952	M
95371	12	Přemysl	Bičovský	18	8	1950	M
26352	13	Jan	Berger	27	11	1955	M
20020	14	Libor	Radimec	22	5	1950	M
49134	15	Jozef	Kukučka	13	3	1957	M
54028	16	Pavel	Chaloupka	4	5	1959	M
61860	17	František	Štambachr	13	2	1953	M
69858	18	Petr	Janečka	25	11	1957	M
81007	19	Marián	Masný	13	8	1950	M
60697	20	Vlastimil	Petržela	20	7	1953	M
41194	21	Zdeněk	Hruška	25	7	1954	M
51677	22	Karel	Stromšík	12	4	1958	M
45636	1	Luis	Guevara Mora	2	9	1961	M
98480	2	Mario	Castillo	30	10	1951	M
58500	3	José Francisco	Jovel	26	5	1951	M
98609	4	Carlos	Recinos	30	6	1950	M
47601	5	Ramón	Fagoaga	12	1	1952	M
55381	6	Joaquín	Ventura	27	10	1956	M
6708	7	Silvio	Aquino	30	6	1949	M
38399	8	José Luis	Rugamas	5	6	1953	M
84407	9	Ever	Hernández	11	12	1958	M
12423	10	Norberto	Huezo	6	6	1956	M
11306	11	Jorge	González	13	3	1958	M
86679	12	Francisco	Osorto	20	3	1957	M
48156	13	José María	Rivas	12	5	1958	M
41807	14	Luis	Ramírez Zapata	6	1	1954	M
49970	15	Jaime	Rodríguez	17	1	1959	M
21488	16	Mauricio	Alfaro	13	2	1956	M
46831	17	Guillermo	Ragazzone	5	1	1956	M
58071	18	Miguel Ángel	Díaz	27	1	1957	M
4162	19	Eduardo	Hernández	31	1	1958	M
29001	20	José Luis	Munguía	28	10	1959	M
79390	1	Ray	Clemence	5	8	1948	M
70102	2	Viv	Anderson	29	7	1956	M
4882	3	Trevor	Brooking	2	10	1948	M
49962	4	Terry	Butcher	28	12	1958	M
40179	5	Steve	Coppell	9	7	1955	M
19836	6	Steve	Foster	24	9	1957	M
50128	7	Kevin	Keegan	14	2	1951	M
65224	8	Trevor	Francis	19	4	1954	M
68542	9	Glenn	Hoddle	27	10	1957	M
31450	10	Terry	McDermott	8	12	1951	M
83210	11	Paul	Mariner	22	5	1953	M
47197	12	Mick	Mills	4	1	1949	M
34569	13	Joe	Corrigan	18	11	1948	M
52968	14	Phil	Neal	20	2	1951	M
72479	15	Graham	Rix	23	10	1957	M
2675	16	Bryan	Robson	11	1	1957	M
59016	17	Kenny	Sansom	26	9	1958	M
68823	18	Phil	Thompson	21	1	1954	M
34141	19	Ray	Wilkins	14	9	1956	M
28235	20	Peter	Withe	30	8	1951	M
34594	21	Tony	Woodcock	6	12	1955	M
20640	22	Peter	Shilton	18	9	1949	M
69834	2	Manuel	Amoros	1	2	1962	M
81366	7	Philippe	Mahut	4	3	1956	M
5511	9	Bernard	Genghini	18	1	1958	M
32542	11	René	Girard	4	4	1954	M
79617	12	Alain	Giresse	2	8	1952	M
14107	13	Jean-François	Larios	27	8	1956	M
76592	14	Jean	Tigana	23	6	1955	M
12716	15	Bruno	Bellone	14	3	1962	M
13150	16	Alain	Couriol	24	10	1958	M
6095	20	Gérard	Soler	29	3	1954	M
17626	21	Jean	Castaneda	20	3	1957	M
98948	22	Jean-Luc	Ettori	29	7	1955	M
6835	1	Salomón	Nazar	7	9	1953	M
62087	2	Efraín	Gutiérrez	7	5	1954	M
72685	3	Jaime	Villegas	5	7	1950	M
62128	4	Fernando	Bulnes	21	10	1946	M
71750	5	Anthony	Costly	13	12	1954	M
33765	6	Ramón	Maradiaga	30	10	1954	M
17413	7	Antonio	Laing	27	12	1958	M
26834	8	Francisco Javier	Toledo	30	9	1959	M
84123	9	Armando	Betancourt	10	10	1957	M
55438	10	Roberto	Figueroa	15	12	1959	M
54224	11	David	Buezo	5	5	1955	M
30605	12	Domingo	Drummond	14	4	1957	M
88933	13	Prudencio	Norales	20	4	1956	M
29948	14	Juan	Cruz	24	6	1959	M
10770	15	Héctor	Zelaya	12	7	1957	M
75470	16	Roberto	Bailey	10	8	1952	M
91620	17	Luis	Cruz	12	6	1949	M
42459	18	Carlos	Caballero	5	12	1958	M
26353	19	Celso	Güity	7	8	1955	M
6989	20	Gilberto	Yearwood	15	3	1956	M
80606	21	Julio César	Arzú	5	6	1954	M
88196	22	Jimmy	Steward	9	12	1946	M
77109	5	Sándor	Müller	21	9	1948	M
45821	6	Imre	Garaba	29	7	1958	M
53791	10	László	Kiss	12	3	1956	M
60461	11	Gábor	Pölöskei	11	10	1960	M
34354	12	Lázár	Szentes	12	12	1955	M
65801	14	Sándor	Sallai	26	3	1960	M
46674	15	Béla	Bodonyi	14	9	1956	M
69257	16	Ferenc	Csongrádi	29	3	1956	M
53311	18	Attila	Kerekes	4	4	1954	M
51494	19	József	Varga	9	10	1954	M
795	20	József	Csuhay	12	7	1957	M
86176	21	Béla	Katzirz	27	7	1953	M
55970	22	Imre	Kiss	10	8	1957	M
42920	2	Franco	Baresi	8	5	1960	M
29143	3	Giuseppe	Bergomi	22	12	1963	M
30672	5	Fulvio	Collovati	9	5	1957	M
73911	8	Pietro	Vierchowod	6	4	1959	M
72980	10	Giuseppe	Dossena	2	5	1958	M
6193	11	Giampiero	Marini	25	2	1951	M
75736	13	Gabriele	Oriali	25	11	1952	M
66365	16	Bruno	Conti	13	3	1955	M
31072	17	Daniele	Massaro	23	5	1961	M
46574	18	Alessandro	Altobelli	28	11	1955	M
89106	21	Franco	Selvaggi	15	5	1953	M
56533	22	Giovanni	Galli	29	4	1958	M
21692	1	Ahmed	Al-Tarabulsi	22	3	1947	M
71779	2	Naeem	Saad	1	10	1957	M
75182	3	Mahboub	Juma'a	17	9	1955	M
15273	4	Jamal	Al-Qabendi	7	4	1959	M
68738	5	Waleed	Al-Jasem	18	11	1959	M
90628	6	Saad	Al-Houti	24	5	1954	M
20299	7	Fathi	Kameel	23	5	1955	M
49203	8	Abdullah	Al-Buloushi	16	2	1960	M
97692	9	Jasem	Yaqoub	25	10	1953	M
88607	10	Abdulaziz	Al-Anberi	3	1	1954	M
90719	11	Nassir	Al-Ghanim	4	4	1961	M
88598	12	Yussef	Al-Suwayed	20	9	1958	M
39423	13	Mubarak	Marzouq	1	1	1961	M
65991	14	Abdullah	Mayouf	3	12	1953	M
8051	15	Sami	Al-Hashash	15	9	1959	M
33410	16	Faisal	Al-Dakhil	13	8	1957	M
61662	17	Hamoud	Al-Shemmari	26	9	1960	M
76079	18	Mohammed	Karam	1	1	1955	M
32314	19	Muayad	Al-Haddad	1	1	1960	M
51432	20	Abdulaziz	Al-Buloushi	4	12	1962	M
79632	21	Adam	Marjam	23	9	1957	M
55917	22	Jasem	Bahman	15	2	1958	M
14752	1	Richard	Wilson	8	5	1956	M
98380	2	Glenn	Dods	7	7	1957	M
35886	3	Ricki	Herbert	10	4	1961	M
39611	4	Brian	Turner	31	7	1949	M
80000	5	Dave	Bright	29	11	1949	M
84240	6	Bobby	Almond	16	4	1951	M
38027	7	Wynton	Rufer	29	12	1962	M
88108	8	Duncan	Cole	12	7	1958	M
50194	9	Steve	Wooddin	16	1	1955	M
23450	10	Steve	Sumner	2	4	1955	M
30806	11	Sam	Malcolmson	2	4	1948	M
39675	12	Keith	MacKay	8	12	1956	M
53388	13	Kenny	Cresswell	4	6	1958	M
15562	14	Adrian	Elrick	29	9	1949	M
98571	15	John	Hill	7	1	1950	M
21395	16	Glen	Adam	22	5	1959	M
81343	17	Allan	Boath	14	2	1958	M
72373	18	Peter	Simonsen	17	4	1959	M
69712	19	Billy	McClure	4	1	1958	M
44600	20	Grant	Turner	7	10	1958	M
69864	21	Barry	Pickering	12	12	1956	M
46351	22	Frank	van Hattum	17	11	1958	M
55794	1	Pat	Jennings	12	6	1945	M
53798	2	Jimmy	Nicholl	28	12	1956	M
40771	3	Mal	Donaghy	13	9	1957	M
99050	4	David	McCreery	16	9	1957	M
52771	5	Chris	Nicholl	12	10	1946	M
62565	6	John	O'Neill	11	3	1958	M
5529	7	Noel	Brotherston	18	11	1956	M
85997	8	Martin	O'Neill	1	3	1952	M
96985	9	Gerry	Armstrong	23	5	1954	M
32829	10	Sammy	McIlroy	2	8	1954	M
76882	11	Billy	Hamilton	9	5	1957	M
76981	12	John	McClelland	7	12	1955	M
65462	13	Sammy	Nelson	1	4	1949	M
13942	14	Tommy	Cassidy	18	11	1950	M
39792	15	Tommy	Finney	6	11	1952	M
62599	16	Norman	Whiteside	7	5	1965	M
4514	17	Jim	Platt	26	1	1952	M
50213	18	Johnny	Jameson	11	3	1958	M
59982	19	Felix	Healy	27	9	1955	M
5291	20	Jim	Cleary	27	5	1956	M
36137	21	Bobby	Campbell	13	9	1956	M
796	22	George	Dunlop	16	1	1956	M
13103	1	Eusebio	Acasuzo	8	4	1952	M
60966	3	Salvador	Salguero	10	8	1951	M
56412	4	Hugo	Gastulo	9	1	1958	M
16659	7	Gerónimo	Barbadillo	24	9	1952	M
23072	9	Julio César	Uribe	9	5	1958	M
51887	12	José	González	10	7	1954	M
39268	13	Oscar	Arizaga	20	8	1957	M
64384	14	Miguel	Gutiérrez	19	11	1956	M
55653	16	Jorge	Olaechea	27	8	1956	M
96784	17	Franco	Navarro	10	11	1961	M
12095	18	Eduardo	Malásquez	13	10	1957	M
79702	22	Luis	Reyna	16	5	1959	M
50717	1	Józef	Młynarczyk	20	9	1953	M
17208	2	Marek	Dziuba	19	12	1955	M
88971	4	Tadeusz	Dolny	7	5	1958	M
43189	5	Paweł	Janas	4	3	1953	M
51539	6	Piotr	Skrobowski	16	10	1961	M
46254	7	Jan	Jałocha	18	7	1957	M
2493	8	Waldemar	Matysik	27	9	1961	M
1165	10	Stefan	Majewski	31	1	1956	M
57931	11	Włodzimierz	Smolarek	16	7	1957	M
40684	13	Andrzej	Buncol	21	9	1959	M
98924	14	Andrzej	Pałasz	22	7	1960	M
91411	15	Włodzimierz	Ciołek	24	3	1956	M
71920	21	Jacek	Kazimierski	17	8	1959	M
76784	22	Piotr	Mowlik	21	4	1951	M
19146	3	Frank	Gray	27	10	1954	M
72942	5	Alan	Hansen	13	6	1955	M
11356	6	Willie	Miller	2	5	1955	M
46604	7	Gordon	Strachan	9	2	1957	M
27545	9	Alan	Brazil	15	6	1959	M
11027	10	John	Wark	4	8	1957	M
26253	12	George	Wood	26	9	1952	M
53843	13	Alex	McLeish	21	1	1959	M
12472	14	David	Narey	12	6	1956	M
53126	17	Allan	Evans	12	10	1956	M
56094	18	Steve	Archibald	27	9	1956	M
15973	19	Paul	Sturrock	10	10	1956	M
85827	20	Davie	Provan	8	5	1956	M
65495	21	George	Burley	3	6	1956	M
85003	22	Jim	Leighton	24	7	1958	M
32342	1	Rinat	Dasayev	13	6	1957	M
49099	2	Tengiz	Sulakvelidze	23	7	1956	M
66593	3	Aleksandr	Chivadze	8	4	1955	M
56334	4	Vagiz	Khidiyatullin	3	3	1959	M
47456	5	Sergei	Baltacha	17	2	1958	M
18580	6	Anatoliy	Demyanenko	19	2	1959	M
93680	7	Ramaz	Shengelia	1	1	1957	M
64968	8	Volodymyr	Bezsonov	5	3	1958	M
18718	9	Yuri	Gavrilov	3	5	1953	M
13514	10	Khoren	Hovhannisyan	10	1	1955	M
3282	11	Oleh	Blokhin	5	11	1952	M
27460	12	Andriy	Bal	16	2	1958	M
5530	13	Vitaly	Daraselia	9	10	1957	M
10493	14	Sergei	Borovsky	29	1	1956	M
35273	15	Sergey	Andreyev	16	5	1956	M
5562	16	Sergey	Rodionov	3	9	1962	M
15023	17	Leonid	Buryak	10	7	1953	M
58072	18	Yuri	Susloparov	14	8	1958	M
12978	19	Vadym	Yevtushenko	1	1	1958	M
116	20	Oleg	Romantsev	4	1	1954	M
90721	21	Viktor	Chanov	21	7	1959	M
5387	22	Vyacheslav	Chanov	23	10	1951	M
96996	2	José Antonio	Camacho	8	6	1955	M
19020	3	Rafael	Gordillo	24	2	1957	M
40490	4	Periko	Alonso	1	2	1953	M
35214	5	Miguel	Tendillo	1	2	1961	M
22433	6	José Ramón	Alexanko	19	5	1956	M
89298	8	not applicable	Joaquín	9	6	1956	M
37218	9	Jesús María	Satrústegui	12	1	1954	M
92317	10	Jesús María	Zamora	1	1	1955	M
65283	11	Roberto López	Ufarte	19	4	1958	M
25980	12	Santiago	Urquiaga	14	4	1958	M
14310	13	Manuel	Jiménez	27	10	1956	M
42410	14	Antonio	Maceda	16	5	1957	M
24553	15	Enrique	Saura	2	8	1954	M
70703	16	Tente	Sánchez	8	10	1956	M
86323	17	Ricardo	Gallego	8	2	1959	M
57343	18	Pedro	Uralde	2	3	1958	M
7171	1	Harald	Schumacher	6	3	1954	M
79689	2	Hans-Peter	Briegel	11	10	1955	M
27251	4	Karlheinz	Förster	25	7	1958	M
31123	5	Bernd	Förster	3	5	1956	M
29426	6	Wolfgang	Dremmler	12	7	1954	M
89975	7	Pierre	Littbarski	16	4	1960	M
89949	9	Horst	Hrubesch	17	4	1951	M
36307	12	Wilfried	Hannes	17	5	1957	M
40743	13	Uwe	Reinders	19	1	1955	M
79344	14	Felix	Magath	26	7	1953	M
45695	15	Uli	Stielike	15	11	1954	M
17092	16	Thomas	Allofs	17	11	1959	M
39771	17	Stephan	Engels	6	9	1960	M
49502	18	Lothar	Matthäus	21	3	1961	M
25464	19	Holger	Hieronymus	22	2	1959	M
85181	21	Bernd	Franke	12	2	1948	M
84364	22	Eike	Immel	27	11	1960	M
76922	1	Dragan	Pantelić	9	12	1951	M
75249	2	Ive	Jerolimov	30	3	1958	M
96969	3	Ivan	Gudelj	21	9	1960	M
84644	4	Velimir	Zajec	12	2	1956	M
17336	5	Nenad	Stojković	26	5	1956	M
85024	6	Zlatko	Krmpotić	7	8	1958	M
67521	8	Edhem	Šljivo	16	3	1950	M
68408	9	Zoran	Vujović	26	8	1958	M
10281	10	Zvonko	Živković	31	10	1959	M
83693	11	Zlatko	Vujović	26	8	1958	M
14305	12	Ivan	Pudar	16	8	1961	M
74361	13	Safet	Sušić	13	4	1955	M
36045	14	Nikola	Jovanović	18	9	1952	M
707	15	Miloš	Hrstić	20	11	1955	M
46658	16	Miloš	Šestić	8	8	1956	M
56193	18	Stjepan	Deverić	20	8	1961	M
40780	19	Vahid	Halilhodžić	15	10	1952	M
24680	21	Predrag	Pašić	18	10	1958	M
84659	22	Ratko	Svilar	6	5	1950	M
33690	1	Nacerdine	Drid	22	1	1957	M
12743	3	Fathi	Chebal	19	8	1956	M
52965	5	Abdellah	Medjadi Liegeon	1	12	1957	M
58877	6	Mohamed	Kaci-Saïd	2	5	1958	M
8861	9	Djamel	Menad	22	7	1960	M
85018	13	Rachid	Harkouk	16	5	1956	M
15505	15	Abdelhamid	Sadmi	1	1	1961	M
65733	17	Fawzi	Benkhalidi	3	2	1963	M
82715	18	Halim	Benmabrouk	25	6	1960	M
97535	19	Mohammed	Chaib	20	5	1957	M
80405	20	Fodil	Megharia	23	5	1961	M
93051	21	Larbi	El Hadi	27	5	1961	M
83449	1	Sergio	Almirón	18	11	1958	M
22408	2	Sergio	Batista	9	11	1962	M
60363	3	Ricardo	Bochini	25	1	1954	M
45025	4	Claudio	Borghi	28	9	1964	M
62815	5	José Luis	Brown	10	11	1956	M
95267	7	Jorge	Burruchaga	9	10	1962	M
61630	8	Néstor	Clausen	29	9	1962	M
22755	9	José Luis	Cuciuffo	1	2	1961	M
70033	12	Héctor	Enrique	26	4	1962	M
69165	13	Oscar	Garré	9	12	1956	M
49676	14	Ricardo	Giusti	11	12	1956	M
24755	15	Luis	Islas	22	12	1965	M
12666	17	Pedro	Pasculli	17	5	1960	M
79080	19	Oscar	Ruggeri	26	1	1962	M
98697	20	Carlos	Tapia	20	8	1962	M
65092	21	Marcelo	Trobbiani	17	2	1955	M
64307	22	Héctor	Zelada	30	4	1957	M
8623	3	Franky	Van der Elst	30	4	1961	M
39297	4	Michel	De Wolf	19	1	1958	M
71806	7	René	Vandereycken	22	7	1953	M
97414	8	Enzo	Scifo	19	2	1966	M
13042	10	Philippe	Desmet	29	11	1958	M
99499	13	Georges	Grün	25	1	1962	M
5723	14	Leo	Clijsters	6	11	1956	M
43888	15	Leo	Van Der Elst	7	1	1962	M
47038	16	Nico	Claesen	7	10	1962	M
24703	18	Daniel	Veyt	9	12	1956	M
93848	19	Hugo	Broos	10	4	1952	M
47067	20	Gilbert	Bodart	2	9	1962	M
95299	21	Stéphane	Demol	11	3	1966	M
92384	22	Patrick	Vervoort	17	1	1965	M
33125	2	not applicable	Édson	3	7	1959	M
60969	7	not applicable	Müller	31	1	1966	M
19190	8	not applicable	Casagrande	15	4	1963	M
90635	9	not applicable	Careca	5	10	1960	M
30573	11	not applicable	Edivaldo	13	4	1962	M
34958	12	Paulo	Vítor	7	6	1957	M
79755	13	not applicable	Josimar	19	9	1961	M
5820	14	Júlio	César	8	3	1963	M
76896	15	not applicable	Alemão	22	11	1961	M
6573	16	Mauro	Galvão	19	12	1961	M
90842	17	not applicable	Branco	4	4	1964	M
50408	19	not applicable	Elzo	22	1	1961	M
12049	20	Paulo	Silas	27	8	1965	M
10596	21	not applicable	Valdo	12	1	1964	M
94024	1	Borislav	Mihaylov	12	2	1963	M
5061	2	Nasko	Sirakov	26	4	1962	M
86608	3	Nikolay	Arabov	21	2	1953	M
28606	4	Petar	Petrov	20	2	1961	M
25752	5	Georgi	Dimitrov	14	1	1959	M
73764	6	Andrey	Zhelyazkov	9	7	1952	M
99064	7	Bozhidar	Iskrenov	1	8	1962	M
9476	8	Ayan	Sadakov	28	9	1961	M
91932	9	Stoycho	Mladenov	24	4	1957	M
32755	10	Zhivko	Gospodinov	6	9	1957	M
76141	11	Plamen	Getov	4	3	1959	M
32447	12	Radoslav	Zdravkov	30	7	1956	M
62546	13	Aleksandar	Markov	17	8	1961	M
7363	14	Plamen	Markov	11	9	1957	M
48970	15	Georgi	Yordanov	21	7	1963	M
33225	16	Vasil	Dragolov	17	8	1962	M
84561	17	Hristo	Kolev	21	9	1964	M
25143	18	Boycho	Velichkov	13	8	1958	M
19526	19	Atanas	Pashev	21	11	1963	M
8726	20	Kostadin	Kostadinov	25	6	1959	M
33846	21	Iliya	Dyakov	28	9	1963	M
52146	22	Iliya	Valov	29	12	1961	M
9660	1	Tino	Lettieri	27	9	1957	M
97018	2	Bob	Lenarduzzi	1	5	1955	M
78960	3	Bruce	Wilson	20	6	1951	M
7554	4	Randy	Ragan	7	6	1959	M
35196	5	Terry	Moore	2	6	1958	M
15173	6	Ian	Bridge	18	9	1959	M
73303	7	Carl	Valentine	4	7	1958	M
61972	8	Gerry	Gray	20	1	1961	M
92139	9	Branko	Šegota	8	6	1961	M
27353	10	Igor	Vrablic	19	7	1965	M
5935	11	Mike	Sweeney	25	12	1959	M
82297	12	Randy	Samuel	23	12	1963	M
21914	13	George	Pakos	14	8	1952	M
67430	14	Dale	Mitchell	21	4	1958	M
73226	15	Paul	James	11	11	1963	M
8567	16	Greg	Ion	12	3	1963	M
50657	17	David	Norman	6	5	1962	M
25508	18	Jamie	Lowery	15	1	1961	M
90988	19	Pasquale	De Luca	26	5	1962	M
13395	20	Colin	Miller	4	10	1964	M
27647	21	Sven	Habermann	3	11	1961	M
33784	22	Paul	Dolan	16	4	1966	M
6115	1	Troels	Rasmussen	4	7	1961	M
46140	2	John	Sivebæk	25	10	1961	M
94731	3	Søren	Busk	10	4	1953	M
40610	4	Morten	Olsen	14	8	1949	M
62631	5	Ivan	Nielsen	9	10	1956	M
92595	6	Søren	Lerby	1	2	1958	M
49069	7	Jan	Mølby	4	7	1963	M
21213	8	Jesper	Olsen	20	3	1961	M
77330	9	Klaus	Berggreen	3	2	1958	M
36502	10	Preben	Elkjær	11	9	1957	M
56788	11	Michael	Laudrup	15	6	1964	M
53824	12	Jens Jørn	Bertelsen	15	2	1952	M
48513	13	Per	Frimann	4	6	1962	M
7140	14	Allan	Simonsen	15	12	1952	M
445	15	Frank	Arnesen	30	9	1956	M
17302	16	Ole	Qvist	25	2	1950	M
58408	17	Kent	Nielsen	28	12	1961	M
60480	18	Flemming	Christensen	10	4	1958	M
92292	19	John	Eriksen	20	11	1957	M
98689	20	Jan	Bartram	6	3	1962	M
4488	21	Henrik	Andersen	7	5	1965	M
83507	22	Lars	Høgh	14	1	1959	M
23718	2	Gary	Stevens	27	3	1963	M
29522	5	Alvin	Martin	29	7	1958	M
65174	9	Mark	Hateley	7	11	1961	M
36651	10	Gary	Lineker	30	11	1960	M
19351	11	Chris	Waddle	14	12	1960	M
81883	13	Chris	Woods	14	11	1959	M
87821	14	Terry	Fenwick	17	11	1959	M
49130	15	Gary	Stevens	30	3	1962	M
53735	16	Peter	Reid	20	6	1956	M
76340	17	Trevor	Steven	21	9	1963	M
78807	18	Steve	Hodge	25	10	1962	M
38921	19	John	Barnes	7	11	1963	M
18335	20	Peter	Beardsley	18	1	1961	M
8967	21	Kerry	Dixon	24	7	1961	M
60826	22	Gary	Bailey	9	8	1958	M
51570	1	Joël	Bats	4	1	1957	M
29650	3	William	Ayache	10	1	1961	M
27495	5	Michel	Bibard	30	11	1958	M
94723	7	Yvon	Le Roux	19	4	1960	M
52595	8	Thierry	Tusseau	19	1	1958	M
643	9	Luis	Fernández	2	10	1959	M
80821	11	Jean-Marc	Ferreri	26	12	1962	M
93959	15	Philippe	Vercruysse	28	1	1962	M
31235	17	Jean-Pierre	Papin	5	11	1963	M
22982	19	Yannick	Stopyra	9	1	1961	M
88945	20	Daniel	Xuereb	22	6	1959	M
51538	21	Philippe	Bergeroo	13	1	1954	M
87726	22	Albert	Rust	10	10	1953	M
71520	1	Péter	Disztl	30	3	1960	M
77817	3	Antal	Róth	14	9	1960	M
4063	5	József	Kardos	22	3	1960	M
67142	7	József	Kiprich	6	9	1963	M
99704	8	Antal	Nagy	17	10	1956	M
52793	9	László	Dajka	29	4	1959	M
88653	10	Lajos	Détári	24	4	1963	M
6745	11	Márton	Esterházy	9	4	1956	M
56500	13	László	Disztl	4	6	1962	M
15144	14	Zoltán	Péter	23	3	1958	M
26969	15	Péter	Hannich	30	3	1957	M
32610	16	József	Nagy	20	10	1960	M
13416	17	Győző	Burcsa	13	3	1954	M
21159	18	József	Szendrei	25	4	1954	M
48639	19	György	Bognár	5	11	1961	M
97362	20	Kálmán	Kovács	11	9	1965	M
81476	21	Gyula	Hajszán	9	10	1961	M
12206	22	József	Andrusch	31	3	1956	M
20424	1	Raad	Hammoudi	1	5	1958	M
20549	2	Maad	Ibrahim	30	6	1960	M
8949	3	Khalil	Allawi	6	9	1958	M
62944	4	Nadhim	Shaker	13	4	1958	M
15649	5	Samir	Shaker	28	2	1958	M
10707	6	Ali	Hussein Shihab	5	5	1961	M
97678	7	Haris	Mohammed	3	3	1958	M
37600	8	Ahmed	Radhi	21	3	1964	M
34556	9	Karim	Saddam	26	5	1960	M
54079	10	Hussein	Saeed	21	1	1958	M
88871	11	Rahim	Hameed	23	5	1963	M
32244	12	Jamal	Ali	2	2	1956	M
56076	13	Karim	Allawi	1	4	1960	M
76810	14	Basil	Gorgis	15	1	1961	M
72587	15	Natiq	Hashim	15	1	1960	M
29742	16	Shaker	Mahmoud	5	5	1963	M
685	17	Anad	Abid	3	8	1955	M
22174	18	Ismail	Mohammed Sharif	19	1	1962	M
57174	19	Basim	Qasim	22	3	1963	M
33838	20	Fatah	Nsaief	2	2	1951	M
34985	21	Ahmad	Jassim	4	5	1960	M
42180	22	Ghanim	Oraibi	16	8	1961	M
99684	5	Sebastiano	Nela	13	3	1961	M
24028	7	Roberto	Tricella	18	3	1959	M
13638	9	Carlo	Ancelotti	10	6	1959	M
49669	10	Salvatore	Bagni	25	9	1956	M
55733	11	Giuseppe	Baresi	7	2	1958	M
50344	12	Franco	Tancredi	10	1	1955	M
32608	13	Fernando	De Napoli	15	3	1964	M
69913	14	Antonio	Di Gennaro	5	10	1958	M
81402	17	Gianluca	Vialli	9	7	1964	M
45432	19	Giuseppe	Galderisi	22	3	1963	M
35253	21	Aldo	Serena	25	6	1960	M
57440	22	Walter	Zenga	28	4	1960	M
96913	1	Pablo	Larios	31	7	1960	M
47178	2	Mario	Trejo	11	2	1956	M
28996	3	Fernando	Quirarte	17	5	1956	M
38416	4	Armando	Manzo	16	10	1958	M
83744	5	Francisco Javier	Cruz	24	5	1966	M
10537	6	Carlos	de los Cobos	10	12	1958	M
19791	7	Miguel	España	4	4	1961	M
3454	8	Alejandro	Domínguez	9	2	1961	M
62984	10	Tomás	Boy	28	6	1951	M
22941	11	Carlos	Hermosillo	24	8	1964	M
43570	12	Ignacio	Rodríguez	13	8	1959	M
59792	13	Javier	Aguirre	1	12	1958	M
56743	14	Felix	Cruz	4	4	1961	M
85837	15	Luis	Flores	8	8	1962	M
67053	16	Carlos	Muñoz	8	9	1962	M
89412	17	Raúl	Servín	29	4	1963	M
63828	18	Rafael	Amador	16	2	1959	M
93110	19	Javier	Hernández	1	8	1961	M
83083	20	Olaf	Heredia	19	10	1957	M
66199	22	Manuel	Negrete	15	5	1959	M
87191	1	Badou	Zaki	2	4	1959	M
92676	2	Labid	Khalifa	1	1	1955	M
40516	3	Abdelmajid	Lamriss	12	2	1959	M
95808	4	Mustafa	El Biyaz	12	12	1960	M
7753	5	Noureddine	Bouyahyaoui	7	1	1955	M
40453	6	Abdelmajid	Dolmy	19	4	1953	M
37917	7	Mustafa	El Haddaoui	28	7	1961	M
99850	8	Aziz	Bouderbala	26	12	1960	M
32922	9	Abdelkrim	Merry	13	1	1955	M
4834	10	Mohamed	Timoumi	15	1	1960	M
87575	11	Mustafa	Merry	21	4	1958	M
37638	12	Salahdine	Hmied	1	9	1961	M
32719	13	Abdelfettah	Rhiati	25	2	1963	M
74260	14	Lahcen	Ouadani	14	7	1959	M
13902	15	Mouncif	El Haddaoui	21	10	1964	M
11961	16	Azzedine	Amanallah	7	4	1956	M
21024	17	Abderrazak	Khairi	20	11	1962	M
43398	18	Mohammed	Sahil	11	10	1963	M
29930	19	Fadel	Jilal	4	3	1964	M
3975	20	Abdellah	Bidane	10	9	1965	M
40996	21	Abdelaziz	Souleimani	30	4	1958	M
79497	22	Abdelfettah	Mouddani	30	7	1956	M
98708	5	Alan	McDonald	12	10	1963	M
84808	7	Steve	Penney	16	1	1964	M
23905	9	Jimmy	Quinn	18	11	1959	M
88012	11	Ian	Stewart	10	9	1961	M
92698	13	Philip	Hughes	19	11	1964	M
19672	15	Nigel	Worthington	4	11	1961	M
99479	16	Paul	Ramsey	3	9	1962	M
74529	17	Colin	Clarke	30	10	1962	M
28922	20	Bernard	McNally	17	2	1963	M
40633	21	David	Campbell	2	6	1965	M
42530	22	Mark	Caughey	31	8	1960	M
47269	1	Roberto	Fernández	9	7	1954	M
13699	2	Juan	Torales	9	5	1956	M
60644	3	César	Zabala	3	6	1961	M
77194	4	Vladimiro	Schettina	8	10	1955	M
20267	5	Rogelio	Delgado	12	10	1959	M
56811	6	Jorge Amado	Nunes	18	10	1961	M
16678	7	Buenaventura	Ferreira	4	7	1960	M
73704	8	Julio César	Romero	28	8	1960	M
29440	9	Roberto	Cabañas	11	4	1961	M
53152	10	Adolfino	Cañete	13	9	1956	M
97522	11	Alfredo	Mendoza	31	12	1963	M
3297	12	Jorge	Battaglia	12	5	1960	M
84056	13	Virginio	Cáceres	21	5	1962	M
69529	14	Luis	Caballero	17	9	1962	M
3360	15	Eufemio	Cabral	21	3	1955	M
37560	16	Jorge	Guasch	17	1	1961	M
34547	17	Francisco	Alcaraz	4	10	1960	M
55219	18	Evaristo	Isasi	26	10	1955	M
38392	19	Rolando	Chilavert	22	5	1961	M
74570	20	Ramón	Hicks	30	5	1959	M
18120	21	Faustino	Alonso	15	2	1961	M
82332	22	Julián	Coronel	23	10	1958	M
31117	2	Kazimierz	Przybyś	11	7	1960	M
146	4	Marek	Ostrowski	22	11	1959	M
71521	7	Ryszard	Tarasiewicz	27	4	1962	M
83573	8	Jan	Urban	14	5	1962	M
39326	9	Jan	Karaś	17	3	1959	M
71979	13	Ryszard	Komornicki	14	8	1959	M
7710	14	Dariusz	Kubicki	6	6	1963	M
86899	17	Andrzej	Zgutczyński	1	1	1958	M
59285	18	Krzysztof	Pawlak	12	2	1958	M
39546	19	Józef	Wandzik	13	8	1963	M
17582	21	Dariusz	Dziekanowski	30	9	1962	M
52039	22	Jan	Furtok	9	3	1962	M
98161	1	Manuel	Bento	25	6	1948	M
37038	2	João	Pinto	21	11	1961	M
22344	3	António	Sousa	28	4	1957	M
63783	4	José	Ribeiro	2	11	1957	M
31048	5	not applicable	Álvaro	3	1	1961	M
81444	6	Carlos	Manuel	15	1	1958	M
97302	7	Jaime	Pacheco	22	7	1958	M
29698	8	not applicable	Frederico	6	4	1957	M
31762	9	Fernando	Gomes	22	11	1956	M
10440	10	Paulo	Futre	28	2	1966	M
94871	11	Fernando	Bandeirinha	26	11	1962	M
34980	12	Jorge	Martins	22	8	1954	M
94216	13	António	Morato	6	11	1964	M
52794	14	Jaime	Magalhães	10	7	1962	M
48881	15	António	Oliveira	8	6	1958	M
3000	16	José	António	29	10	1957	M
88661	17	not applicable	Diamantino	3	8	1959	M
87641	18	Luís	Sobrinho	5	5	1961	M
77856	19	Rui	Águas	28	4	1960	M
7955	20	Augusto	Inácio	1	2	1955	M
61802	21	António	André	24	12	1957	M
37242	22	Vítor	Damas	8	10	1947	M
5434	2	Richard	Gough	5	4	1962	M
64688	3	Maurice	Malpas	3	8	1962	M
8096	8	Roy	Aitken	24	11	1958	M
65888	9	Eamonn	Bannon	18	4	1958	M
78666	10	Jim	Bett	25	11	1959	M
42726	11	Paul	McStay	22	10	1964	M
51002	12	Andy	Goram	13	4	1964	M
36038	13	Steve	Nicol	11	12	1961	M
39517	15	Arthur	Albiston	14	7	1957	M
31710	16	Frank	McAvennie	22	11	1959	M
47824	18	Graeme	Sharp	16	10	1960	M
97239	19	Charlie	Nicholas	30	12	1961	M
89287	21	Davie	Cooper	25	2	1956	M
77268	1	Byung-deuk	Cho	26	5	1958	M
43950	2	Kyung-hoon	Park	19	1	1961	M
65387	3	Jong-soo	Chung	27	3	1961	M
45849	4	Kwang-rae	Cho	19	3	1954	M
68971	5	Yong-hwan	Chung	10	2	1960	M
83876	6	Tae-ho	Lee	29	1	1961	M
19309	7	Jong-boo	Kim	3	11	1965	M
46375	8	Young-jeung	Cho	18	8	1954	M
51349	9	Soon-ho	Choi	10	1	1962	M
99813	10	Chang-sun	Park	2	2	1954	M
13141	11	Bum-kun	Cha	21	5	1953	M
70602	12	Pyung-seok	Kim	22	9	1958	M
66410	13	Soo-jin	Noh	10	2	1962	M
74032	14	Min-kook	Cho	5	7	1963	M
87197	15	Byung-ok	Yoo	2	3	1964	M
95664	16	Joo-sung	Kim	17	1	1966	M
64475	17	Jung-moo	Huh	13	1	1955	M
99042	18	Sam-soo	Kim	8	2	1963	M
50938	19	Byung-joo	Byun	26	4	1961	M
53955	20	Yong-se	Kim	21	4	1960	M
53803	21	Yun-kyo	Oh	25	5	1960	M
18924	22	Deuk-soo	Kang	16	8	1961	M
4915	4	Gennady	Morozov	30	12	1962	M
93918	6	Aleksandr	Bubnov	10	10	1955	M
34497	7	Ivan	Yaremchuk	19	3	1962	M
33328	8	Pavel	Yakovenko	19	12	1964	M
27906	9	Oleksandr	Zavarov	20	4	1961	M
86826	10	Oleh	Kuznetsov	22	3	1963	M
48718	13	Gennadiy	Litovchenko	11	9	1963	M
51110	15	Nikolay	Larionov	19	1	1957	M
10906	18	Oleh	Protasov	4	2	1964	M
10855	19	Ihor	Belanov	25	9	1960	M
86677	20	Sergei	Aleinikov	7	11	1961	M
16126	21	Vasyl	Rats	25	4	1961	M
8071	22	Serhiy	Krakovskiy	11	8	1960	M
63214	1	Andoni	Zubizarreta	23	10	1961	M
72141	2	not applicable	Tomás	9	8	1960	M
91970	5	not applicable	Víctor	15	3	1957	M
32414	7	Juan Antonio	Señor	26	8	1958	M
93792	8	Andoni	Goikoetxea	23	8	1956	M
12940	9	Emilio	Butragueño	22	7	1963	M
12398	10	Francisco José	Carrasco	6	3	1959	M
70569	11	Julio	Alberto	7	10	1958	M
95106	12	Quique	Setién	27	9	1958	M
31693	15	not applicable	Chendo	12	10	1961	M
91175	16	Hipólito	Rincón	28	4	1957	M
2901	17	not applicable	Francisco	1	11	1962	M
14296	18	Ramón	Calderé	16	1	1959	M
18314	19	Julio	Salinas	11	9	1962	M
74307	20	not applicable	Eloy	10	7	1964	M
6498	21	not applicable	Míchel	23	3	1963	M
98382	22	Juan Carlos	Ablanedo	2	9	1963	M
73100	1	Rodolfo	Rodríguez	20	1	1956	M
86817	2	Nelson	Gutiérrez	13	4	1962	M
48167	3	Eduardo Mario	Acevedo	25	9	1959	M
29429	4	Víctor	Diogo	9	4	1958	M
89543	5	Miguel	Bossio	10	2	1960	M
57952	6	José	Batista	6	3	1962	M
68463	7	Antonio	Alzamendi	7	6	1956	M
38492	8	Jorge	Barrios	24	1	1961	M
94995	9	Jorge	da Silva	11	12	1961	M
36582	10	Enzo	Francescoli	12	11	1961	M
37351	11	Sergio	Santín	6	8	1956	M
22385	12	Fernando	Álvez	4	9	1959	M
77490	13	César	Vega	2	9	1959	M
3963	14	Darío	Pereyra	19	10	1956	M
72094	15	Eliseo	Rivero	27	12	1957	M
66014	16	Mario	Saralegui	24	4	1959	M
19175	17	José	Zalazar	26	10	1963	M
83805	18	Rubén	Paz	8	8	1959	M
97584	19	Venancio	Ramos	20	6	1959	M
57189	20	Carlos	Aguilera	21	9	1964	M
18562	21	Wilmar	Cabrera	31	7	1959	M
489	22	Celso	Otero	1	2	1958	M
67713	3	Andreas	Brehme	9	11	1960	M
66165	5	Matthias	Herget	14	11	1955	M
36201	6	Norbert	Eder	7	11	1955	M
4572	9	Rudi	Völler	13	4	1960	M
71616	12	Uli	Stein	23	10	1954	M
65532	13	Karl	Allgöwer	5	1	1957	M
59388	14	Thomas	Berthold	12	11	1964	M
23204	15	Klaus	Augenthaler	26	9	1957	M
45408	16	Olaf	Thon	1	5	1966	M
91180	17	Ditmar	Jakobs	28	8	1953	M
93701	18	Uwe	Rahn	21	5	1962	M
95392	19	Klaus	Allofs	5	12	1956	M
27194	20	Dieter	Hoeneß	7	1	1953	M
96946	21	Wolfgang	Rolff	26	12	1959	M
7031	3	Abel	Balbo	1	6	1966	M
14841	4	José	Basualdo	20	6	1963	M
6684	5	Edgardo	Bauza	26	1	1958	M
35873	8	Claudio	Caniggia	9	1	1967	M
53936	9	Gustavo	Dezotti	14	2	1964	M
64003	11	Néstor	Fabbri	29	4	1968	M
34056	12	Sergio	Goycochea	17	10	1963	M
23349	13	Néstor	Lorenzo	28	2	1966	M
31161	15	Pedro	Monzón	23	2	1962	M
82949	17	Roberto Néstor	Sensini	12	10	1966	M
80379	18	José	Serrizuela	16	6	1962	M
14628	20	Juan	Simón	2	3	1960	M
30977	21	Pedro	Troglio	28	7	1965	M
15632	22	Fabián	Cancelarich	20	12	1965	M
22801	2	Ernst	Aigner	31	10	1966	M
57468	3	Robert	Pecl	15	11	1965	M
46006	4	Anton	Pfeffer	17	8	1965	M
77198	5	Peter	Schöttel	26	3	1967	M
69681	6	Manfred	Zsak	22	12	1964	M
76884	7	Kurt	Russ	23	11	1964	M
67942	8	Peter	Artner	20	5	1966	M
16938	9	Toni	Polster	10	3	1964	M
52446	10	Manfred	Linzmaier	27	8	1962	M
6378	11	Alfred	Hörtnagl	24	9	1966	M
11735	12	Michael	Baur	16	4	1969	M
7284	13	Andreas	Ogris	7	10	1964	M
79953	14	Gerhard	Rodax	29	8	1965	M
68014	15	Christian	Keglevits	29	1	1961	M
67426	16	Andreas	Reisinger	14	10	1963	M
67358	17	Heimo	Pfeifenberger	29	12	1966	M
57682	18	Michael	Streiter	19	1	1966	M
16277	19	Gerald	Glatzmayer	14	12	1968	M
46897	20	Andi	Herzog	10	9	1968	M
80487	21	Michael	Konsel	6	3	1962	M
91339	22	Otto	Konrad	1	11	1964	M
531	1	Michel	Preud'homme	24	1	1959	M
43307	3	Philippe	Albert	10	8	1967	M
51650	5	Bruno	Versavel	27	8	1967	M
35636	6	Marc	Emmers	25	2	1966	M
28230	9	Marc	Degryse	4	9	1965	M
11791	15	Jean-François	De Sart	18	12	1961	M
37431	17	Pascal	Plovie	7	5	1965	M
33618	18	Lorenzo	Staelens	30	4	1964	M
3300	19	Marc	Van Der Linden	4	2	1964	M
72937	20	Filip	De Wilde	5	7	1964	M
69659	21	Marc	Wilmots	22	2	1969	M
31850	1	Cláudio	Taffarel	8	5	1966	M
26340	2	not applicable	Jorginho	17	8	1964	M
88506	3	Ricardo	Gomes	13	12	1964	M
32466	4	not applicable	Dunga	31	10	1963	M
66554	7	not applicable	Bismarck	11	9	1969	M
61251	11	not applicable	Romário	29	1	1966	M
12036	12	not applicable	Acácio	20	1	1959	M
62375	13	Carlos	Mozer	19	9	1960	M
56505	14	not applicable	Aldair	30	11	1965	M
68671	16	not applicable	Bebeto	16	2	1964	M
52379	17	Renato	Gaúcho	9	9	1962	M
78793	18	not applicable	Mazinho	8	4	1966	M
61247	19	Ricardo	Rocha	11	9	1962	M
69952	20	not applicable	Tita	1	4	1958	M
73607	22	not applicable	Zé Carlos	7	2	1962	M
84420	2	André	Kana-Biyik	1	9	1965	M
56577	3	Jules	Onana	12	6	1964	M
31657	4	Benjamin	Massing	20	6	1962	M
31884	5	Bertin	Ebwellé	11	9	1962	M
77989	7	François	Omam-Biyik	21	5	1966	M
12458	8	Émile	Mbouh	30	5	1966	M
59402	10	Louis-Paul	M'Fédé	26	2	1961	M
41084	11	Eugène	Ekéké	30	5	1960	M
79721	12	Alphonse	Yombi	30	6	1969	M
81131	13	Jean-Claude	Pagal	15	9	1964	M
8703	14	Stephen	Tataw	31	3	1963	M
94752	15	Thomas	Libiih	17	11	1967	M
53341	17	Victor	N'Dip	18	8	1967	M
36769	18	Bonaventure	Djonkep	20	8	1961	M
19849	19	Roger	Feutmba	31	10	1968	M
64478	20	Cyrille	Makanaky	28	6	1965	M
3377	21	Emmanuel	Maboang	27	11	1968	M
93402	22	Jacques	Songo'o	17	3	1964	M
31928	1	René	Higuita	27	8	1966	M
70177	2	Andrés	Escobar	13	3	1967	M
14496	3	Gildardo	Gómez	13	10	1963	M
43980	4	Luis Fernando	Herrera	12	6	1962	M
39384	5	León	Villa	12	1	1960	M
31126	6	José Ricardo	Pérez	24	10	1963	M
53398	7	Carlos	Estrada	1	11	1961	M
31825	8	Gabriel	Gómez	8	12	1959	M
43732	9	Miguel	Guerrero	7	9	1967	M
49600	10	Carlos	Valderrama	2	9	1961	M
2405	11	Bernardo	Redín	26	2	1963	M
65731	12	Eduardo	Niño	8	8	1967	M
41062	13	Carlos	Hoyos	28	2	1962	M
10890	14	Leonel	Álvarez	29	7	1965	M
92695	15	Luis Carlos	Perea	29	12	1963	M
82012	16	Arnoldo	Iguarán	18	1	1957	M
96992	17	Geovanis	Cassiani	10	1	1970	M
13552	18	Wílmer	Cabrera	15	9	1967	M
69504	19	Freddy	Rincón	14	8	1966	M
75417	20	Luis	Fajardo	18	8	1963	M
33086	21	Alexis	Mendoza	8	11	1961	M
7687	22	Rubén Darío	Hernández	19	2	1965	M
62978	1	Luis Gabelo	Conejo	1	1	1960	M
65985	2	Vladimir	Quesada	12	5	1966	M
59912	3	Róger	Flores	26	5	1959	M
74237	4	Rónald	González Brenes	8	8	1970	M
50080	5	Marvin	Obando	4	4	1960	M
78926	6	José Carlos	Chaves	3	9	1958	M
2273	7	Hernán	Medford	23	5	1968	M
13444	8	Germán	Chavarría	19	3	1958	M
35501	9	Alexandre	Guimarães	7	11	1959	M
27437	10	Oscar	Ramírez	8	12	1964	M
1259	11	Claudio	Jara	6	5	1959	M
16382	12	Róger	Gómez	7	2	1965	M
64783	13	Miguel	Davis	18	6	1966	M
18941	14	Juan	Cayasso	24	6	1961	M
49136	15	Rónald	Marín	2	11	1962	M
73174	16	José	Jaikel	3	4	1966	M
87653	17	Roy	Myers	13	4	1969	M
73643	18	Geovanny	Jara	20	7	1967	M
37790	19	Héctor	Marchena	4	1	1965	M
48788	20	Mauricio	Montero	19	10	1963	M
81990	21	Hermidio	Barrantes	2	9	1964	M
39680	22	Miguel	Segura	2	9	1963	M
76459	1	Jan	Stejskal	15	1	1962	M
20237	2	Július	Bielik	8	3	1962	M
40265	3	Miroslav	Kadlec	22	6	1964	M
73737	4	Ivan	Hašek	6	9	1963	M
57995	5	Ján	Kocian	13	3	1958	M
20647	6	František	Straka	21	5	1958	M
8239	7	Michal	Bílek	13	4	1965	M
52500	8	Jozef	Chovanec	7	3	1960	M
16313	9	Luboš	Kubík	20	1	1964	M
71260	10	Tomáš	Skuhravý	7	9	1965	M
85306	11	Ľubomír	Moravčík	22	6	1965	M
17800	12	Peter	Fieber	16	5	1964	M
82871	13	Jiří	Němec	15	5	1966	M
78227	14	Vladimír	Weiss	22	9	1964	M
28182	15	Vladimír	Kinier	6	4	1958	M
58445	16	Viliam	Hýravý	26	11	1962	M
65434	17	Ivo	Knoflíček	23	2	1962	M
99987	18	Milan	Luhový	1	1	1963	M
71732	19	Stanislav	Griga	4	11	1961	M
48690	20	Václav	Němeček	25	1	1967	M
22231	21	Luděk	Mikloško	9	12	1961	M
14432	22	Peter	Palúch	17	2	1958	M
42749	1	Ahmed	Shobair	28	9	1960	M
41175	2	Ibrahim	Hassan	10	8	1966	M
51328	3	Rabie	Yassin	7	9	1960	M
11562	4	Hany	Ramzy	10	3	1969	M
31758	5	Hesham	Yakan	10	8	1962	M
17383	6	Ashraf	Kasem	25	7	1966	M
54444	7	Ismail	Youssef	28	6	1964	M
62193	8	Magdi	Abdelghani	27	7	1959	M
89810	9	Hossam	Hassan	10	8	1966	M
73679	10	Gamal	Abdel-Hamid	24	11	1957	M
57839	11	Tarek	Soliman	24	1	1962	M
62807	12	Taher	Abouzeid	10	4	1962	M
53055	13	Ahmed	Ramzy	25	10	1965	M
47911	14	Alaa	Maihoub	19	1	1963	M
10496	15	Saber	Eid	1	5	1959	M
7223	16	Magdy	Tolba	24	2	1964	M
1224	17	Ayman	Shawky	9	12	1962	M
83361	18	Osama	Orabi	22	1	1962	M
26446	19	Adel	Abdel Rahman	11	12	1967	M
41648	20	Ahmed	El-Kass	8	7	1965	M
72591	21	Ayman	Taher	7	1	1966	M
97395	22	Thabet	El-Batal	16	9	1953	M
67307	3	Stuart	Pearce	24	4	1962	M
17303	4	Neil	Webb	30	7	1963	M
55650	5	Des	Walker	26	11	1965	M
96960	12	Paul	Parker	4	4	1964	M
68510	14	Mark	Wright	1	8	1963	M
10265	15	Tony	Dorigo	31	12	1965	M
27404	16	Steve	McMahon	20	8	1961	M
34450	17	David	Platt	10	6	1966	M
6127	19	Paul	Gascoigne	27	5	1967	M
81	21	Steve	Bull	28	3	1965	M
13285	22	David	Seaman	19	9	1963	M
35719	4	Luigi	De Agostini	7	4	1961	M
67143	5	Ciro	Ferrara	11	2	1967	M
47366	6	Riccardo	Ferri	20	8	1963	M
43222	7	Paolo	Maldini	26	6	1968	M
67585	10	Nicola	Berti	14	4	1967	M
61854	12	Stefano	Tacconi	13	5	1957	M
75545	13	Giuseppe	Giannini	20	8	1964	M
13438	14	Giancarlo	Marocchi	4	7	1965	M
78756	15	Roberto	Baggio	18	2	1967	M
49269	16	Andrea	Carnevale	12	1	1961	M
38434	17	Roberto	Donadoni	9	9	1963	M
25410	18	Roberto	Mancini	27	11	1964	M
76544	19	Salvatore	Schillaci	1	12	1964	M
88002	22	Gianluca	Pagliuca	18	12	1966	M
58282	1	Hans	van Breukelen	4	10	1956	M
37630	2	Berry	van Aerle	8	12	1962	M
92391	3	Frank	Rijkaard	30	9	1962	M
72919	4	Ronald	Koeman	21	3	1963	M
73794	5	Adri	van Tiggelen	16	6	1957	M
50869	6	Jan	Wouters	17	7	1960	M
48431	7	Erwin	Koeman	20	9	1961	M
19670	8	Gerald	Vanenburg	5	3	1964	M
76874	9	Marco	van Basten	31	10	1964	M
32830	10	Ruud	Gullit	1	9	1962	M
47334	11	Richard	Witschge	20	9	1969	M
11241	12	Wim	Kieft	12	11	1962	M
88192	13	Graeme	Rutjes	26	3	1960	M
52936	14	John	van 't Schip	30	11	1963	M
3942	15	Bryan	Roy	12	2	1970	M
53103	16	Joop	Hiele	25	12	1958	M
15631	17	Hans	Gillhaus	5	11	1963	M
77764	18	Henk	Fraser	7	7	1966	M
84043	19	John	van Loen	4	2	1965	M
42249	20	Aron	Winter	1	3	1967	M
29008	21	Danny	Blind	1	8	1961	M
30771	22	Stanley	Menzo	15	10	1963	M
67839	1	Pat	Bonner	24	5	1960	M
24199	2	Chris	Morris	24	12	1963	M
69817	3	Steve	Staunton	19	1	1969	M
8289	4	Mick	McCarthy	7	2	1959	M
15882	5	Kevin	Moran	29	4	1956	M
4391	6	Ronnie	Whelan	25	9	1961	M
96122	7	Paul	McGrath	4	12	1959	M
95491	8	Ray	Houghton	9	1	1962	M
42603	9	John	Aldridge	18	9	1958	M
94106	10	Tony	Cascarino	1	9	1962	M
72379	11	Kevin	Sheedy	21	10	1959	M
64796	12	David	O'Leary	2	5	1958	M
28854	13	Andy	Townsend	23	7	1963	M
66543	14	Chris	Hughton	11	12	1958	M
56580	15	Bernie	Slaven	13	11	1960	M
52963	16	John	Sheridan	1	10	1964	M
51629	17	Niall	Quinn	6	10	1966	M
90888	18	Frank	Stapleton	10	7	1956	M
98535	19	David	Kelly	25	11	1965	M
61238	20	John	Byrne	1	2	1961	M
87036	21	Alan	McLoughlin	20	4	1967	M
57771	22	Gerry	Peyton	20	5	1956	M
71173	1	Silviu	Lung	9	9	1956	M
94011	2	Mircea	Rednic	9	4	1962	M
99719	3	Michael	Klein	10	10	1959	M
42321	4	Ioan	Andone	15	3	1960	M
23176	5	Iosif	Rotariu	27	9	1962	M
19537	6	Gheorghe	Popescu	9	10	1967	M
1137	7	Marius	Lăcătuș	5	4	1964	M
83453	8	Ioan	Sabău	12	2	1968	M
58563	9	Rodion	Cămătaru	22	6	1958	M
30739	10	Gheorghe	Hagi	5	2	1965	M
49988	11	Dănuț	Lupu	27	2	1967	M
44978	12	Bogdan	Stelea	5	12	1967	M
25437	13	Adrian	Popescu	26	6	1960	M
69340	14	Florin	Răducioiu	17	3	1970	M
34184	15	Dorin	Mateuț	5	8	1965	M
40531	16	Daniel	Timofte	1	10	1967	M
54322	17	Ilie	Dumitrescu	6	1	1969	M
67274	18	Gabi	Balint	3	1	1963	M
42807	19	Emil	Săndoi	1	3	1965	M
78546	20	Zsolt	Muzsnay	20	8	1965	M
86528	21	Ioan	Lupescu	9	12	1968	M
63813	22	Gheorghe	Liliac	22	4	1959	M
17223	7	Mo	Johnston	13	4	1963	M
10580	9	Ally	McCoist	24	9	1962	M
10435	10	Murdo	MacLeod	24	9	1958	M
16627	11	Gary	Gillespie	5	7	1960	M
39265	13	Gordon	Durie	6	12	1965	M
34150	14	Alan	McInally	10	2	1963	M
46094	15	Craig	Levein	22	10	1964	M
49470	16	Stuart	McCall	10	6	1964	M
76645	17	Stewart	McKimmie	27	10	1962	M
39646	18	John	Collins	31	1	1968	M
95626	19	David	McPherson	28	1	1964	M
9546	20	Gary	McAllister	25	12	1964	M
56270	21	Robert	Fleck	11	8	1965	M
18873	22	Bryan	Gunn	22	12	1963	M
95438	1	Poong-joo	Kim	1	10	1961	M
35322	3	Kang-hee	Choi	12	4	1959	M
99575	4	Deok-yeo	Yoon	25	3	1961	M
43076	8	Hae-won	Chung	1	7	1959	M
76411	9	Kwan	Hwangbo	1	3	1965	M
47850	10	Sang-yoon	Lee	10	4	1969	M
86017	12	Heung-sil	Lee	10	7	1961	M
90303	17	Sang-bum	Gu	15	6	1964	M
15222	18	Sun-hong	Hwang	14	7	1968	M
93046	19	Gi-dong	Jeong	13	5	1961	M
55097	20	Myung-bo	Hong	12	2	1969	M
20285	21	In-young	Choi	5	3	1962	M
50333	22	Young-jin	Lee	27	10	1963	M
77250	11	Igor	Dobrovolski	27	8	1967	M
99207	12	Aleksandr	Borodyuk	30	11	1962	M
15788	13	Akhrik	Tsveiba	10	9	1966	M
35793	14	Volodymyr	Lyutyi	24	4	1962	M
5885	17	Andrei	Zygmantovich	2	12	1962	M
10165	18	Igor	Shalimov	2	2	1969	M
45890	19	Sergei	Fokin	26	7	1961	M
6372	20	Sergei	Gorlukovich	18	11	1961	M
10577	21	Valeri	Broshin	19	10	1962	M
77395	22	Aleksandr	Uvarov	13	1	1960	M
80363	3	Manuel	Jiménez	21	1	1964	M
75527	4	Genar	Andrinúa	9	5	1964	M
59110	5	Manuel	Sanchís	23	5	1965	M
40929	6	Rafael Martín	Vázquez	25	9	1965	M
46166	7	Miguel	Pardeza	8	2	1965	M
90670	8	Quique	Sánchez Flores	2	2	1965	M
84197	10	not applicable	Fernando	11	9	1965	M
81270	11	Francisco	Villarroya	6	8	1966	M
76590	12	Rafael	Alkorta	16	9	1968	M
82189	14	Alberto	Górriz	16	2	1958	M
61508	15	not applicable	Roberto	5	7	1962	M
44411	16	José María	Bakero	11	2	1963	M
35246	17	Fernando	Hierro	23	3	1968	M
10514	18	Rafael	Paz	2	8	1965	M
61411	20	not applicable	Manolo	17	1	1965	M
49442	22	José Manuel	Ochotorena	16	1	1961	M
83613	1	Sven	Andersson	6	10	1963	M
39219	2	Jan	Eriksson	24	8	1967	M
31156	3	Glenn	Hysén	30	10	1959	M
22289	4	Peter	Larsson	8	3	1961	M
75066	5	Roger	Ljung	8	1	1966	M
23360	6	Roland	Nilsson	27	11	1963	M
26709	7	Niklas	Nyhlén	21	3	1966	M
63692	8	Stefan	Schwarz	18	4	1969	M
2017	9	Leif	Engqvist	30	7	1962	M
21234	10	Klas	Ingesson	20	8	1968	M
75272	11	Ulrik	Jansson	2	2	1968	M
41130	12	Lars	Eriksson	21	9	1965	M
59805	13	Anders	Limpar	24	9	1965	M
71492	14	Joakim	Nilsson	31	3	1966	M
67329	15	Glenn	Strömberg	5	1	1960	M
92339	16	Jonas	Thern	20	3	1967	M
26281	17	Tomas	Brolin	29	11	1969	M
60456	18	Johnny	Ekström	5	3	1965	M
27804	19	Mats	Gren	20	12	1963	M
81063	20	Mats	Magnusson	10	7	1963	M
46228	21	Stefan	Pettersson	22	3	1963	M
94051	22	Thomas	Ravelli	13	8	1959	M
95570	1	Abdullah	Musa	2	3	1958	M
23285	2	Khalil	Ghanim	12	11	1964	M
56780	3	Ali Thani	Jumaa	18	8	1968	M
36777	4	Mubarak	Ghanim	3	9	1963	M
52938	5	Abdualla	Sultan	1	10	1963	M
35056	6	Abdulrahman	Mohamed	1	10	1963	M
27017	7	Fahad	Khamees	24	1	1962	M
90097	8	Khalid	Ismaïl	7	7	1965	M
91477	9	Abdulaziz	Mohamed	12	12	1965	M
11032	10	Adnan	Al-Talyani	30	10	1964	M
17799	11	Zuhair	Bakheet	13	7	1967	M
16899	12	Hussain	Ghuloum	24	9	1969	M
96771	13	Hassan	Mohamed	23	8	1962	M
77154	14	Nasir	Khamees	2	8	1965	M
99834	15	Ibrahim	Meer	16	7	1967	M
16918	16	Mohamed	Salim	13	1	1968	M
234	17	Muhsin	Musabah	1	10	1964	M
53430	18	Fahad	Abdulrahman	10	10	1962	M
27206	19	Eissa	Meer	16	7	1967	M
50458	20	Yousuf	Hussain	8	7	1965	M
17103	21	Abdulrahman	Al-Haddad	23	3	1966	M
42685	22	Abdulqadir	Hassan	15	4	1962	M
43736	1	Tony	Meola	21	2	1969	M
28361	2	Steve	Trittschuh	24	4	1965	M
53572	3	John	Doyle	16	3	1966	M
85296	4	Jimmy	Banks	2	9	1964	M
51936	5	Mike	Windischmann	6	12	1965	M
14008	6	John	Harkes	8	3	1967	M
7720	7	Tab	Ramos	21	9	1966	M
44443	8	Brian	Bliss	28	9	1965	M
21609	9	Christopher	Sullivan	18	4	1965	M
88114	10	Peter	Vermes	21	11	1966	M
67232	11	Eric	Wynalda	9	6	1969	M
86766	12	Paul	Krumpe	4	3	1963	M
72794	13	Eric	Eichmann	7	5	1965	M
28894	14	John	Stollmeyer	25	10	1962	M
95563	15	Desmond	Armstrong	2	11	1964	M
93627	16	Bruce	Murray	25	1	1966	M
12470	17	Marcelo	Balboa	8	8	1967	M
7553	18	Kasey	Keller	29	11	1969	M
5791	19	Chris	Henderson	11	12	1970	M
82723	20	Paul	Caligiuri	9	3	1964	M
52133	21	Neil	Covone	31	8	1969	M
94232	22	David	Vanole	6	2	1963	M
58404	3	Hugo	de León	27	2	1958	M
53299	4	José Oscar	Herrera	17	6	1965	M
69960	5	José	Perdomo	5	1	1965	M
77465	6	Alfonso	Domínguez	24	9	1965	M
68471	8	Santiago	Ostolaza	10	7	1962	M
68611	11	Rubén	Sosa	25	4	1966	M
62514	12	Eduardo	Pereira	21	3	1954	M
70218	13	Daniel	Revelez	30	9	1959	M
2668	14	José	Pintos Saldanha	25	3	1964	M
85271	15	Gabriel	Correa	13	1	1968	M
52902	16	Pablo	Bengoechea	27	6	1965	M
97602	17	Sergio	Martínez	15	2	1969	M
30100	19	Daniel	Fonseca	13	9	1969	M
80877	20	Ruben	Pereira	28	1	1968	M
14403	21	William	Castro	22	5	1962	M
2096	22	Javier	Zeoli	2	5	1962	M
59164	1	Bodo	Illgner	7	4	1967	M
74629	2	Stefan	Reuter	16	10	1966	M
83968	4	Jürgen	Kohler	6	10	1965	M
51921	6	Guido	Buchwald	24	1	1961	M
77552	8	Thomas	Häßler	30	5	1966	M
3526	11	Frank	Mill	23	7	1958	M
70770	12	Raimond	Aumann	12	10	1963	M
43380	13	Karl-Heinz	Riedle	16	9	1965	M
60022	15	Uwe	Bein	26	9	1960	M
25067	16	Paul	Steiner	23	1	1957	M
37963	17	Andreas	Möller	2	9	1967	M
91373	18	Jürgen	Klinsmann	30	7	1964	M
55047	19	Hans	Pflügler	27	3	1960	M
46363	21	Günter	Hermann	5	12	1960	M
45405	22	Andreas	Köpke	12	3	1962	M
94391	1	Tomislav	Ivković	11	8	1960	M
63160	2	Vujadin	Stanojković	10	9	1963	M
71342	3	Predrag	Spasić	13	5	1965	M
9094	4	Zoran	Vulić	4	10	1961	M
85893	5	Faruk	Hadžibegić	7	10	1957	M
1298	6	Davor	Jozić	22	9	1960	M
71107	7	Dragoljub	Brnović	2	11	1963	M
31892	9	Darko	Pančev	7	9	1965	M
93318	10	Dragan	Stojković	3	3	1965	M
34572	12	Fahrudin	Omerović	26	8	1961	M
54317	13	Srečko	Katanec	16	7	1963	M
50470	14	Alen	Bokšić	21	1	1970	M
62861	15	Robert	Prosinečki	12	1	1969	M
48922	16	Refik	Šabanadžović	2	8	1965	M
26414	17	Robert	Jarni	26	10	1968	M
153	18	Mirsad	Baljić	4	3	1962	M
18303	19	Dejan	Savićević	15	9	1966	M
58374	20	Davor	Šuker	1	1	1968	M
93042	21	Andrej	Panadić	9	3	1969	M
39053	22	Dragoje	Leković	21	11	1967	M
53935	1	not applicable	Meg	1	1	1956	F
70959	2	Rosa	Lima	2	5	1964	F
15996	3	not applicable	Marisa	10	8	1966	F
41343	4	not applicable	Elane	4	6	1968	F
24769	5	not applicable	Marcinha	22	8	1962	F
89759	6	not applicable	Fanta	14	9	1966	F
87338	7	not applicable	Pelézinha	12	3	1964	F
1608	8	not applicable	Solange	29	3	1969	F
40825	9	not applicable	Adriana	26	12	1968	F
18032	10	not applicable	Roseli	7	9	1969	F
17405	11	not applicable	Cenira	12	2	1965	F
60468	12	not applicable	Miriam	4	5	1965	F
74741	13	Márcia	Taffarel	15	3	1968	F
54299	14	not applicable	Nalvinha	14	7	1965	F
26383	15	not applicable	Pretinha	19	5	1975	F
93081	16	not applicable	Doralice	23	10	1963	F
21261	17	not applicable	Danda	1	4	1964	F
48120	18	not applicable	Fia	1	4	1964	F
62296	1	Honglian	Zhong	27	10	1967	F
60340	2	Xia	Chen	26	11	1969	F
84060	3	Li	Ma	3	3	1969	F
24862	4	Xiufu	Li	28	6	1965	F
2688	5	Yang	Zhou	2	1	1971	F
70203	6	Qingxia	Shui	18	12	1966	F
15966	7	Weiying	Wu	19	1	1969	F
33672	8	Hua	Zhou	3	10	1969	F
14903	9	Wen	Sun	6	4	1973	F
10128	10	Ailing	Liu	2	5	1967	F
49949	11	Qingmei	Sun	19	6	1966	F
78729	12	Lirong	Wen	2	10	1969	F
27968	13	Lijie	Niu	12	4	1969	F
24949	14	Yan	Zhang	6	8	1972	F
47025	15	Haiying	Wei	5	1	1971	F
58392	16	Hongdong	Zhang	20	3	1969	F
21302	17	Tao	Zhu	20	11	1974	F
85220	18	Sa	Li	3	1	1968	F
4945	1	Li-chyn	Hong	23	5	1970	F
48100	2	Hsiu-mei	Liu	28	11	1972	F
54832	3	Shwu-ju	Chen	2	3	1965	F
44333	4	Chu-yin	Lo	6	10	1965	F
69316	5	Hsiu-lin	Chen	12	12	1973	F
19063	6	Tai-ying	Chou	16	8	1963	F
34495	7	Mei-chun	Lin	11	1	1974	F
54250	8	Su-jean	Shieh	10	2	1969	F
81582	9	Su-ching	Wu	21	7	1970	F
78731	10	Yu-chuan	Huang	17	2	1971	F
15723	11	Chia-cheng	Hsu	7	6	1969	F
75654	12	Lan-fen	Lan	22	11	1973	F
1739	13	Chao-chun	Lin	31	10	1972	F
8129	14	Chiao-lin	Ko	14	9	1973	F
18257	15	Min-hsun	Wu	26	9	1974	F
91091	16	Shu-chin	Chen	19	9	1974	F
5432	17	Mei-jih	Lin	27	2	1972	F
54286	18	Hui-fang	Lin	6	10	1973	F
81922	1	Helle	Bjerregaard	21	6	1968	F
43536	2	Karina	Sefron	2	7	1967	F
1721	3	Jannie	Hansen	6	10	1963	F
50609	4	Bonny	Madsen	10	8	1967	F
91753	5	Helle	Rotbøll	8	10	1963	F
3790	6	Mette	Nielsen	15	6	1964	F
25916	7	Susan	Mackensie	24	12	1962	F
8319	8	Lisbet	Kolding	6	4	1965	F
65510	9	Annie	Gam-Pedersen	5	7	1965	F
42117	10	Helle	Jensen	23	3	1969	F
23712	11	Hanne	Nissen	21	11	1970	F
80365	12	Irene	Stelling	25	7	1971	F
88749	13	Annette	Thychosen	30	8	1968	F
43393	14	Marianne	Jensen	14	1	1970	F
74955	15	Rikke	Holm	22	3	1972	F
37679	16	Gitte	Hansen	21	9	1961	F
43998	17	Lotte	Bagge	21	5	1968	F
75034	18	Janne	Rasmussen	18	7	1970	F
36095	1	Marion	Isbert	25	2	1964	F
51730	2	Britta	Unsleber	25	12	1966	F
63276	3	Birgitt	Austermühl	8	10	1965	F
95856	4	Jutta	Nardenbach	13	10	1968	F
44228	5	Doris	Fitschen	25	10	1968	F
48884	6	Frauke	Kuhlmann	27	9	1966	F
21423	7	Martina	Voss	22	12	1967	F
53366	8	Bettina	Wiegmann	7	10	1971	F
30335	9	Heidi	Mohr	29	5	1967	F
10757	10	Silvia	Neid	2	5	1964	F
39883	11	Beate	Wendt	21	9	1971	F
76215	12	Elke	Walther	1	4	1971	F
10018	13	Roswitha	Bindl	14	1	1965	F
16920	14	Petra	Damm	20	3	1961	F
25144	15	Christine	Paul	21	1	1965	F
47441	16	Gudrun	Gottschlich	23	5	1970	F
8619	17	Sandra	Hengst	12	4	1973	F
58592	18	Michaela	Kubat	10	4	1972	F
97777	1	Stefania	Antonini	10	10	1970	F
23151	2	Paola	Bonato	31	1	1961	F
10951	3	Marina	Cordenons	12	1	1969	F
75268	4	Maria	Mariotti	27	4	1964	F
90918	5	Raffaella	Salmaso	16	4	1968	F
2315	6	Maura	Furlotti	12	9	1957	F
12901	7	Silvia	Fiorini	24	12	1969	F
11183	8	Federica	D'Astolfo	27	10	1966	F
89767	9	Carolina	Morace	5	2	1964	F
65393	10	Feriana	Ferraguzzi	20	2	1959	F
57735	11	Adele	Marsiletti	7	11	1964	F
71237	12	Giorgia	Brenzan	21	8	1967	F
40727	13	Emma	Iozzelli	12	6	1966	F
52430	14	Elisabetta	Bavagnoli	3	9	1963	F
49968	15	Anna	Mega	21	10	1962	F
47660	16	Fabiana	Correra	1	10	1967	F
7005	17	Nausica	Pedersoli	17	4	1969	F
50912	18	Rita	Guarino	31	1	1971	F
89545	1	Masae	Suzuki	21	1	1957	F
87015	2	Midori	Honda	16	11	1961	F
27625	3	Yumi	Watanabe	2	7	1970	F
64525	4	Mayumi	Kaji	28	6	1964	F
85493	5	Sayuri	Yamaguchi	25	7	1966	F
50928	6	Yoko	Takahagi	17	4	1969	F
89192	7	Yumi	Obe	15	2	1975	F
28976	8	Michiko	Matsuda	26	10	1966	F
41046	9	Akemi	Noda	13	10	1969	F
95229	10	Asako	Takakura	19	4	1968	F
91514	11	Futaba	Kioka	22	11	1965	F
46260	12	Megumi	Sakata	18	10	1971	F
13746	13	Kyoko	Kuroda	8	5	1970	F
57072	14	Etsuko	Handa	10	5	1965	F
77882	15	Kaori	Nagamine	3	6	1968	F
48890	16	Takako	Tezuka	6	11	1970	F
10451	17	Yuriko	Mizuma	22	7	1970	F
29094	18	Tamaki	Uchiyama	13	12	1972	F
42839	1	Leslie	King	13	11	1963	F
21831	2	Jocelyn	Parr	5	3	1967	F
54269	3	Cinnamon	Chaney	10	1	1969	F
7169	4	Lynley	Pedruco	11	10	1960	F
2950	5	Deborah	Pullen	20	9	1961	F
55801	6	Lorraine	Taylor	20	9	1961	F
37507	7	Maureen	Jacobson	7	12	1961	F
79951	8	Monique	van de Elzen	17	7	1967	F
16994	9	Wendi	Henderson	16	7	1971	F
96912	10	Donna	Baker	27	2	1966	F
62147	11	Amanda	Crawford	16	2	1971	F
23793	12	Julia	Campbell	1	4	1965	F
35084	13	Kim	Nye	10	5	1961	F
93036	14	Maria	George	3	3	1965	F
75601	15	Terry	McCahill	1	9	1970	F
95282	16	Vivienne	Robertson	18	6	1955	F
31253	17	Lynne	Warring	1	12	1963	F
85265	18	Anne	Smith	27	9	1951	F
52654	1	Ann	Chiejine	2	2	1974	F
81179	2	Diana	Nwaiwu	10	10	1973	F
26950	3	Ngozi	Ezeocha	12	10	1973	F
65225	4	Adaku	Okoroafor	18	11	1974	F
53349	5	Omo-Love	Branch	10	1	1974	F
89903	6	Nkechi	Mbilitam	5	4	1974	F
76883	7	Chioma	Ajunwa	25	12	1971	F
33681	8	Rita	Nwadike	3	11	1974	F
32241	9	Ngozi Eucharia	Uche	18	6	1973	F
57488	10	Mavis	Ogun	24	8	1973	F
8232	11	Gift	Showemimo	24	5	1974	F
59238	12	Florence	Omagbemi	2	2	1975	F
68759	13	Nkiru	Okosieme	1	3	1972	F
436	14	Phoebe	Ebimiekumo	17	1	1974	F
30411	15	Ann	Mukoro	27	5	1975	F
42059	16	Lydia	Koyonda	29	5	1974	F
24476	17	Edith	Eluma	27	9	1958	F
55437	18	Rachael	Yamala	12	2	1975	F
89376	1	Reidun	Seth	9	6	1966	F
29059	2	Cathrine	Zaborowski	2	8	1971	F
8403	3	Trine	Stenberg	6	12	1969	F
67204	4	Gro	Espeseth	30	10	1972	F
36817	5	Gunn	Nyborg	21	3	1960	F
6023	6	Agnete	Carlsen	15	1	1971	F
24254	7	Tone	Haugen	6	2	1964	F
91065	8	Heidi	Støre	4	7	1963	F
84389	9	Hege	Riise	18	7	1969	F
58688	10	Linda	Medalen	17	6	1965	F
35393	11	Birthe	Hegstad	23	7	1966	F
39183	12	Bente	Nordby	23	7	1974	F
58483	13	Liv	Strædet	21	10	1964	F
3648	14	Margunn	Humlestøl	25	1	1970	F
84789	15	Anette	Igland	2	10	1971	F
18995	16	Tina	Svensson	16	11	1966	F
54099	17	Ellen	Scheel	26	11	1968	F
41995	18	Hilde	Strømsvold	17	8	1967	F
16323	1	Elisabeth	Leidinge	6	3	1957	F
8153	2	Malin	Lundgren	9	3	1967	F
96118	3	Anette	Hansson	2	5	1963	F
35861	4	Camilla	Fors	24	4	1969	F
57532	5	Eva	Zeikfalvy	18	4	1967	F
84182	6	Malin	Swedberg	15	9	1968	F
12441	7	Pia	Sundhage	13	2	1960	F
24936	8	Susanne	Hedberg	26	6	1972	F
57215	9	Helen	Johansson	9	7	1965	F
33270	10	Lena	Videkull	9	12	1962	F
81571	11	Anneli	Andelén	21	6	1968	F
1275	12	Ing-Marie	Olsson	23	2	1966	F
42701	13	Marie	Ewrelius	31	8	1967	F
31691	14	Camilla	Svensson-Gustafsson	20	1	1969	F
98080	15	Helen	Nilsson	24	11	1970	F
2652	16	Ingrid	Johansson	9	7	1965	F
3801	17	Marie	Karlsson	4	12	1963	F
99713	18	Pärnilla	Larsson	19	2	1969	F
65159	1	Mary	Harvey	4	6	1965	F
90564	2	April	Heinrichs	27	2	1964	F
48379	3	Shannon	Higgins	20	2	1968	F
56906	4	Carla	Overbeck	9	5	1968	F
29594	5	Lori	Henry	20	3	1966	F
99201	6	Brandi	Chastain	21	7	1968	F
36970	7	Tracey	Bates	5	5	1967	F
10856	8	Linda	Hamilton	4	6	1969	F
28901	9	Mia	Hamm	17	3	1972	F
54794	10	Michelle	Akers	1	2	1966	F
89416	11	Julie	Foudy	23	1	1971	F
99328	12	Carin	Jennings-Gabarra	9	1	1965	F
25850	13	Kristine	Lilly	22	7	1971	F
30345	14	Joy	Fawcett	8	2	1968	F
5397	15	Wendy	Gebauer	25	12	1966	F
30282	16	Debbie	Belkin	27	5	1966	F
13711	17	Amy	Allmann	25	3	1965	F
83809	18	Kim	Maslin-Kammerdeiner	12	8	1964	F
53817	2	Sergio	Vázquez	23	11	1965	M
28816	3	José	Chamot	17	5	1969	M
78898	5	Fernando	Redondo	6	6	1969	M
84542	9	Gabriel	Batistuta	1	2	1969	M
16961	11	Ramón	Medina Bello	29	4	1966	M
41616	13	Fernando	Cáceres	7	2	1969	M
6370	14	Diego	Simeone	28	4	1970	M
55916	15	Jorge	Borelli	2	11	1964	M
69852	16	Hernán	Díaz	26	2	1965	M
65	17	Ariel	Ortega	4	3	1974	M
15142	18	Hugo	Pérez	6	10	1968	M
27629	20	Leonardo	Rodríguez	27	8	1966	M
93732	21	Alejandro	Mancuso	4	9	1968	M
87458	22	Norberto	Scoponi	13	1	1961	M
72736	2	Dirk	Medved	15	6	1968	M
10129	3	Vital	Borkelmans	1	6	1963	M
61846	5	Rudi	Smidts	12	8	1963	M
51869	8	Luc	Nilis	25	5	1967	M
33197	16	Danny	Boffin	10	7	1965	M
83199	17	Josip	Weber	16	11	1964	M
71601	19	Eric	Van Meir	28	2	1968	M
54160	20	Dany	Verlinden	15	8	1963	M
90526	21	Stéphane	van der Heyden	3	7	1969	M
48499	22	Pascal	Renier	3	8	1971	M
83061	1	Carlos	Trucco	8	8	1957	M
6645	2	Juan Manuel	Peña	17	1	1973	M
47593	3	Marco	Sandy	29	8	1971	M
49642	4	Miguel	Rimba	1	11	1967	M
74977	5	Gustavo	Quinteros	15	2	1965	M
92800	6	Carlos	Borja	25	12	1956	M
44632	7	Mario	Pinedo	9	4	1964	M
59235	8	José Milton	Melgar	20	9	1959	M
20960	9	Álvaro	Peña	11	2	1965	M
22812	10	Marco	Etcheverry	26	9	1970	M
11058	11	Jaime	Moreno	19	1	1974	M
23356	12	Darío	Rojas	20	1	1960	M
70512	13	Modesto	Soruco	12	2	1966	M
9423	14	Mauricio	Ramos	23	9	1969	M
61814	15	Vladimir	Soria	15	7	1964	M
26034	16	Luis	Cristaldo	31	8	1969	M
77469	17	Óscar	Sánchez	16	7	1971	M
97920	18	William	Ramallo	4	7	1963	M
66585	19	Marcelo	Torrico	11	1	1972	M
90575	20	Ramiro	Castillo	27	3	1966	M
9978	21	Erwin	Sánchez	19	10	1969	M
84079	22	Julio César	Baldivieso	2	12	1971	M
74676	4	not applicable	Ronaldão	19	6	1965	M
12551	5	Mauro	Silva	12	1	1968	M
12418	9	not applicable	Zinho	17	6	1967	M
93386	10	not applicable	Raí	15	5	1965	M
2858	12	not applicable	Zetti	10	1	1965	M
91718	14	not applicable	Cafu	7	6	1970	M
7679	15	Márcio	Santos	15	9	1969	M
72471	16	not applicable	Leonardo	5	9	1969	M
86509	18	Paulo	Sérgio	2	6	1969	M
62722	20	not applicable	Ronaldo	18	9	1976	M
81097	21	not applicable	Viola	1	1	1969	M
12835	22	Gilmar	Rinaldi	13	1	1959	M
88510	2	Emil	Kremenliev	13	8	1969	M
47670	3	Trifon	Ivanov	27	7	1965	M
6964	4	Tsanko	Tsvetanov	6	1	1970	M
7517	5	Petar	Hubchev	26	2	1964	M
56496	6	Zlatko	Yankov	7	6	1966	M
23633	7	Emil	Kostadinov	12	8	1967	M
81648	8	Hristo	Stoichkov	8	2	1966	M
19567	9	Yordan	Letchkov	9	7	1967	M
40793	11	Daniel	Borimirov	15	1	1970	M
31099	12	Plamen	Nikolov	20	8	1961	M
99271	13	Ivaylo	Yordanov	22	4	1968	M
67920	14	Boncho	Genchev	7	7	1964	M
40749	15	Nikolay	Iliev	31	3	1964	M
48990	16	Iliyan	Kiryakov	4	8	1967	M
24215	17	Petar	Mihtarski	15	7	1966	M
96679	18	Petar	Aleksandrov	7	12	1962	M
36178	19	Georgi	Georgiev	10	1	1963	M
22562	20	Krasimir	Balakov	29	3	1966	M
51016	21	Velko	Yotov	26	8	1970	M
33264	22	Ivaylo	Andonov	14	8	1967	M
98173	3	Rigobert	Song	1	7	1976	M
33542	4	Samuel	Ekemé	12	7	1966	M
6434	12	Paul	Loga	14	8	1969	M
7520	13	Raymond	Kalla	22	4	1975	M
68499	15	Hans	Agbo	26	9	1967	M
63012	16	Alphonse	Tchami	14	9	1971	M
63522	17	Marc-Vivien	Foé	1	5	1975	M
1632	18	Jean-Pierre	Fiala	22	4	1969	M
43560	19	David	Embé	13	11	1973	M
49445	20	Georges	Mouyémé	15	4	1971	M
24621	1	Óscar	Córdoba	3	2	1970	M
42991	5	Hermán	Gaviria	27	11	1969	M
23692	7	Antony	de Ávila	21	12	1962	M
19743	8	John Harold	Lozano	30	3	1972	M
27157	9	Iván	Valenciano	18	3	1972	M
55994	11	Adolfo	Valencia	6	2	1968	M
2080	12	Faryd	Mondragón	21	6	1971	M
41894	13	Néstor	Ortiz	20	9	1968	M
76247	16	Víctor	Aristizábal	9	12	1971	M
80178	17	Mauricio	Serna	22	1	1968	M
28003	18	Óscar	Cortés	19	10	1968	M
6957	20	Wilson	Pérez	6	8	1967	M
10444	21	Faustino	Asprilla	10	11	1969	M
42369	22	José María	Pazo	4	4	1964	M
47227	2	Thomas	Strunz	25	4	1968	M
87830	5	Thomas	Helmer	21	4	1965	M
71595	11	Stefan	Kuntz	30	10	1962	M
48681	15	Maurizio	Gaudino	12	12	1966	M
5385	16	Matthias	Sammer	5	9	1967	M
68490	17	Martin	Wagner	24	2	1968	M
9705	19	Ulf	Kirsten	4	12	1965	M
61872	20	Stefan	Effenberg	2	8	1968	M
78222	21	Mario	Basler	18	12	1968	M
33751	22	Oliver	Kahn	15	6	1969	M
7892	1	Antonis	Minou	4	5	1958	M
54632	2	Stratos	Apostolakis	11	5	1964	M
86801	3	Thanasis	Kolitsidakis	20	11	1966	M
43850	4	Stelios	Manolas	13	7	1961	M
59135	5	Ioannis	Kalitzakis	10	2	1966	M
6459	6	Panagiotis	Tsalouchidis	30	3	1963	M
68230	7	Dimitris	Saravakos	26	7	1961	M
68233	8	Nikos	Nioplias	17	1	1965	M
16110	9	Nikos	Machlas	16	6	1973	M
12695	10	Tasos	Mitropoulos	23	8	1957	M
75239	11	Nikos	Tsiantakis	20	10	1963	M
83956	12	Spiros	Marangos	20	2	1967	M
35810	13	Vaios	Karagiannis	25	6	1968	M
11986	14	Vasilis	Dimitriadis	1	2	1966	M
70338	15	Christos	Karkamanis	22	9	1969	M
98623	16	Alexis	Alexoudis	20	6	1972	M
38731	17	Minas	Hantzidis	4	7	1966	M
68585	18	Kyriakos	Karataidis	4	7	1965	M
87563	19	Savvas	Kofidis	21	3	1961	M
24277	20	Elias	Atmatsidis	24	4	1969	M
80966	21	Alexis	Alexandris	21	10	1968	M
20597	22	Alexis	Alexiou	8	9	1963	M
83615	2	Luigi	Apolloni	2	5	1967	M
24741	3	Antonio	Benarrivo	21	8	1968	M
36036	4	Alessandro	Costacurta	24	4	1966	M
98192	7	Lorenzo	Minotti	8	2	1967	M
2430	8	Roberto	Mussi	25	8	1963	M
80307	9	Mauro	Tassotti	19	1	1960	M
87231	11	Demetrio	Albertini	23	8	1971	M
93900	12	Luca	Marchegiani	22	2	1966	M
52474	13	Dino	Baggio	24	7	1971	M
96535	15	Antonio	Conte	31	7	1969	M
38178	17	Alberigo	Evani	1	1	1963	M
26730	18	Pierluigi	Casiraghi	4	3	1969	M
32071	20	Giuseppe	Signori	17	2	1968	M
78280	21	Gianfranco	Zola	5	7	1966	M
14001	22	Luca	Bucci	13	3	1969	M
50787	1	Jorge	Campos	15	10	1966	M
78308	2	Claudio	Suárez	17	12	1968	M
9363	3	Juan	de Dios Ramírez Perales	8	3	1969	M
28217	4	Ignacio	Ambríz	7	2	1965	M
21741	5	Ramón	Ramírez	5	12	1969	M
40627	6	Marcelino	Bernal	27	5	1962	M
21495	8	Alberto	García Aspe	11	5	1967	M
46904	10	Luis	García Postigo	1	6	1969	M
97279	11	not applicable	Zague	23	5	1967	M
53503	12	Félix	Fernández	11	1	1967	M
70776	13	Juan Carlos	Chávez	18	1	1967	M
97610	14	Joaquín	del Olmo	20	4	1969	M
93217	15	Missael	Espinoza	12	4	1965	M
16030	16	Luis Antonio	Valdéz	1	7	1965	M
82483	17	Benjamín	Galindo	11	12	1960	M
81177	18	José Luis	Salgado	3	4	1966	M
87112	19	Luis Miguel	Salvador	26	2	1968	M
35042	20	Jorge	Rodríguez	18	4	1968	M
74788	21	Raúl	Gutiérrez	16	10	1966	M
10416	22	Adrián	Chávez	27	6	1962	M
74924	1	Khalil	Azmi	23	8	1964	M
61342	2	Nacer	Abdellah	3	3	1966	M
19991	3	Abdelkrim	El Hadrioui	6	3	1972	M
82124	4	Tahar	El Khalej	16	6	1968	M
77110	5	Smahi	Triki	1	8	1967	M
96824	6	Noureddine	Naybet	10	2	1970	M
45896	7	Mustapha	Hadji	16	11	1971	M
84885	8	Rachid	Azzouzi	10	1	1971	M
9278	9	Mohammed	Chaouch	12	12	1966	M
8730	11	Rachid	Daoudi	21	2	1966	M
58464	12	Said	Dghay	14	1	1964	M
61219	13	Ahmed	Bahja	21	12	1970	M
39021	14	Ahmed	Masbahi	17	1	1966	M
48036	15	El Arbi Hababi	Hababi	12	8	1967	M
89133	16	Hassan	Nader	8	7	1965	M
33746	17	Abdeslam	Laghrissi	5	1	1962	M
36579	18	Rachid	Neqrouz	10	4	1972	M
91608	19	Abdelmajid	Bouyboud	24	10	1966	M
96488	20	Hassan	Kachloul	19	2	1973	M
16451	21	Mohamed	Samadi	21	3	1970	M
62567	22	Zakaria	Alaoui	17	6	1966	M
15829	1	Ed	de Goey	20	12	1966	M
32212	2	Frank	de Boer	15	5	1970	M
51357	5	Rob	Witschge	22	8	1966	M
33834	7	Marc	Overmars	29	3	1973	M
27957	8	Wim	Jonk	12	10	1966	M
92804	9	Ronald	de Boer	15	5	1970	M
22409	10	Dennis	Bergkamp	10	5	1969	M
4823	12	John	Bosman	1	2	1965	M
26572	13	Edwin	van der Sar	29	10	1970	M
49163	14	Ulrich	van Gobbel	16	1	1971	M
92458	16	Arthur	Numan	14	12	1969	M
20827	17	Gaston	Taument	1	10	1970	M
61116	18	Stan	Valckx	20	10	1963	M
99166	19	Peter	van Vossen	21	4	1968	M
25693	21	John	de Wolf	10	12	1962	M
22351	22	Theo	Snelders	7	12	1963	M
75277	1	Peter	Rufai	24	8	1963	M
39450	2	Augustine	Eguavoen	19	8	1965	M
72134	3	Benedict	Iroha	29	11	1969	M
46986	4	Stephen	Keshi	23	1	1962	M
74808	5	Uche	Okechukwu	27	9	1967	M
91949	6	Chidi	Nwanu	1	1	1967	M
54287	7	Finidi	George	15	4	1971	M
91871	8	Thompson	Oliha	4	10	1968	M
98228	9	Rashidi	Yekini	23	10	1963	M
83122	10	Jay-Jay	Okocha	14	8	1973	M
22820	11	Emmanuel	Amunike	25	12	1970	M
72487	12	Samson	Siasia	14	8	1967	M
26103	13	Emeka	Ezeugo	16	12	1965	M
84893	14	Daniel	Amokachi	30	12	1972	M
41790	15	Sunday	Oliseh	14	9	1974	M
25342	16	Alloysius	Agu	12	7	1967	M
25715	17	Victor	Ikpeba	12	6	1973	M
95888	18	Efan	Ekoku	8	6	1967	M
74911	19	Michael	Emenalo	14	7	1965	M
34180	20	Uche	Okafor	8	8	1967	M
56969	21	Mutiu	Adepoju	22	12	1970	M
77276	22	Wilfred	Agbonavbare	5	10	1966	M
3090	1	Erik	Thorstvedt	28	10	1962	M
83152	2	Gunnar	Halle	11	8	1965	M
2163	3	Erland	Johnsen	5	4	1967	M
90792	4	Rune	Bratseth	19	3	1961	M
52878	5	Stig Inge	Bjørnebye	11	12	1969	M
94465	6	Jostein	Flo	3	10	1964	M
48934	7	Erik	Mykland	21	7	1971	M
61579	8	Øyvind	Leonhardsen	17	8	1970	M
73648	9	Jan Åge	Fjørtoft	10	1	1967	M
72296	10	Kjetil	Rekdal	6	11	1968	M
31031	11	Mini	Jakobsen	8	11	1965	M
14379	12	Frode	Grodås	24	10	1964	M
48304	13	Ola	By Rise	14	11	1960	M
47297	14	Roger	Nilsen	8	8	1969	M
24240	15	Karl Petter	Løken	14	8	1966	M
63024	16	Gøran	Sørloth	16	7	1962	M
59890	17	Dan	Eggen	13	1	1970	M
93679	18	Alf-Inge	Håland	23	11	1972	M
21663	19	Roar	Strand	2	2	1970	M
25644	20	Henning	Berg	1	9	1969	M
96984	21	Sigurd	Rushfeldt	11	12	1972	M
50065	22	Lars	Bohinen	8	9	1969	M
25274	2	Denis	Irwin	31	10	1965	M
99685	3	Terry	Phelan	16	3	1967	M
91106	6	Roy	Keane	10	8	1971	M
7683	12	Gary	Kelly	9	7	1974	M
20706	13	Alan	Kernaghan	25	4	1967	M
28514	14	Phil	Babb	30	10	1970	M
90357	15	Tommy	Coyne	14	11	1962	M
11747	17	Eddie	McGoldrick	30	4	1965	M
15705	21	Jason	McAteer	18	6	1971	M
33377	22	Alan	Kelly	11	8	1968	M
29644	1	Florin	Prunea	8	8	1968	M
12625	2	Dan	Petrescu	22	12	1967	M
87995	3	Daniel	Prodan	23	3	1972	M
43639	4	Miodrag	Belodedici	20	5	1964	M
4888	7	Dorinel	Munteanu	25	6	1968	M
83265	8	Iulian	Chiriță	2	2	1967	M
79864	13	Tibor	Selymes	14	5	1970	M
81047	14	Gheorghe	Mihali	9	12	1965	M
11979	15	Basarab	Panduru	11	7	1970	M
15773	16	Ion	Vlădoiu	5	11	1968	M
67833	17	Viorel	Moldovan	8	7	1972	M
17898	18	Constantin	Gâlcă	8	3	1972	M
42028	19	Corneliu	Papură	5	9	1973	M
44448	20	Ovidiu	Stîngă	5	12	1972	M
266	21	Marian	Ivan	6	1	1969	M
47501	22	Ștefan	Preda	18	6	1970	M
82210	1	Stanislav	Cherchesov	2	9	1963	M
82492	2	Dmitri	Kuznetsov	28	8	1965	M
95639	4	Dmitri	Galiamin	8	1	1963	M
70700	5	Yuri	Nikiforov	16	9	1970	M
66957	6	Vladislav	Ternavsky	2	5	1969	M
8785	7	Andrey	Pyatnitsky	27	9	1967	M
46886	8	Dmitri	Popov	27	2	1967	M
73354	9	Oleg	Salenko	25	10	1969	M
48249	10	Valeri	Karpin	2	2	1969	M
76498	11	Vladimir	Beschastnykh	1	4	1974	M
1806	12	Omari	Tetradze	13	10	1969	M
88486	14	Igor	Korneev	4	9	1967	M
42532	15	Dmitri	Radchenko	2	12	1970	M
54805	16	Dmitri	Kharine	16	8	1968	M
65049	17	Ilya	Tsymbalar	17	6	1969	M
83394	18	Viktor	Onopko	14	10	1969	M
76220	19	Aleksandr	Mostovoi	22	8	1968	M
93191	20	Igor	Lediakhov	22	5	1968	M
69635	21	Dmitri	Khlestov	21	1	1971	M
46493	22	Sergei	Yuran	11	6	1969	M
12996	1	Mohamed	Al-Deayea	2	8	1972	M
60332	2	Abdullah	Al-Dosari	1	11	1969	M
44462	3	Mohammed	Al-Khilaiwi	21	8	1971	M
50171	4	Abdullah	Sulaiman Zubromawi	15	11	1973	M
51472	5	Ahmed	Jamil Madani	6	1	1970	M
21550	6	Fuad	Anwar	13	10	1972	M
39267	7	Fahad	Al-Ghesheyan	1	8	1973	M
23379	8	Fahad	Al-Bishi	10	9	1965	M
3048	9	Majed	Abdullah	1	11	1959	M
41428	10	Saeed	Al-Owairan	19	8	1967	M
89920	11	Fahad	Al-Mehallel	11	11	1970	M
88041	12	Sami	Al-Jaber	11	12	1972	M
29132	13	Mohamed	Abd Al-Jawad	28	11	1962	M
78753	14	Khalid	Al-Muwallid	23	11	1971	M
77098	15	Saleh	Al-Dawod	24	9	1968	M
75079	16	Talal	Jebreen	25	9	1973	M
2755	17	Yassir	Al-Taifi	10	5	1971	M
22789	18	Awad	Al-Anazi	24	9	1968	M
61224	19	Hamzah	Saleh	19	4	1967	M
60814	20	Hamzah	Idris	8	10	1972	M
43829	21	Hussein	Al-Sadiq	15	10	1973	M
36914	22	Ibrahim	Al-Helwah	18	8	1972	M
93017	2	Jong-son	Chung	20	3	1966	M
68563	3	Jong-hwa	Lee	20	7	1963	M
53258	4	Pan-keun	Kim	5	3	1966	M
92215	5	Jung-bae	Park	19	2	1967	M
97902	7	Hong-gi	Shin	4	5	1968	M
9742	8	Jung-yoon	Noh	28	3	1971	M
39863	10	Jeong-woon	Ko	27	6	1966	M
65525	11	Jung-won	Seo	17	12	1970	M
51868	12	Young-il	Choi	25	4	1966	M
35590	13	Ik-soo	An	6	5	1965	M
57959	14	Dae-shik	Choi	10	1	1965	M
52179	15	Jin-ho	Cho	2	8	1973	M
55350	16	Seok-ju	Ha	20	2	1968	M
64379	19	Moon-sik	Choi	6	1	1971	M
34573	21	Chul-woo	Park	29	9	1965	M
95122	22	Woon-jae	Lee	26	4	1973	M
59647	2	Albert	Ferrer	6	6	1970	M
20256	3	Jorge	Otero	8	3	1969	M
80697	4	Paco	Camarasa	27	9	1967	M
24945	5	not applicable	Abelardo	19	3	1970	M
619	7	Andoni	Goikoetxea	21	10	1965	M
60964	8	Julen	Guerrero	7	1	1974	M
78385	9	Josep	Guardiola	18	1	1971	M
23403	11	Txiki	Begiristain	12	8	1964	M
96053	12	not applicable	Sergi	28	12	1971	M
16059	13	Santiago	Cañizares	18	12	1969	M
18572	14	not applicable	Juanele	10	4	1971	M
97666	15	José Luis	Caminero	8	11	1967	M
97482	16	Felipe	Miñambres	29	4	1965	M
74638	17	not applicable	Voro	9	10	1963	M
3307	20	Miguel Ángel	Nadal	28	7	1966	M
38878	21	Luis	Enrique	8	5	1970	M
60604	22	Julen	Lopetegui	28	8	1966	M
63774	3	Patrik	Andersson	18	8	1971	M
39860	4	Joachim	Björklund	15	3	1971	M
42895	7	Henrik	Larsson	20	9	1971	M
63429	10	Martin	Dahlin	16	4	1968	M
34801	13	Mikael	Nilsson	28	9	1968	M
72332	14	Pontus	Kåmark	5	4	1969	M
30568	15	Teddy	Lučić	15	4	1973	M
80132	17	Stefan	Rehn	22	9	1966	M
66178	18	Håkan	Mild	14	6	1971	M
60371	19	Kennet	Andersson	6	10	1967	M
39634	20	Magnus	Erlingmark	8	7	1968	M
65081	21	Jesper	Blomqvist	5	2	1974	M
7902	22	Magnus	Hedman	19	3	1973	M
9954	1	Marco	Pascolo	9	5	1966	M
6183	2	Marc	Hottiger	7	11	1967	M
14226	3	Yvan	Quentin	2	5	1970	M
94830	4	Dominique	Herr	25	10	1965	M
2900	5	Alain	Geiger	5	11	1960	M
26437	6	Georges	Bregy	17	1	1958	M
56818	7	Alain	Sutter	22	1	1968	M
92672	8	Christophe	Ohrel	7	4	1968	M
1678	9	Adrian	Knup	2	7	1968	M
78318	10	Ciriaco	Sforza	2	3	1970	M
28977	11	Stéphane	Chapuisat	28	6	1969	M
91107	12	Stephan	Lehmann	15	8	1963	M
12283	13	André	Egli	8	5	1958	M
76790	14	Nestor	Subiat	23	4	1966	M
43247	15	Marco	Grassi	8	8	1968	M
10499	16	Thomas	Bickel	6	10	1963	M
94720	17	Sébastien	Fournier	27	6	1971	M
71232	18	Martin	Rueda	9	1	1963	M
82747	19	Jürg	Studer	8	9	1966	M
80695	20	Patrick	Sylvestre	1	9	1968	M
16251	21	Thomas	Wyss	29	8	1966	M
31551	22	Martin	Brunner	23	4	1963	M
76583	2	Mike	Lapper	28	9	1970	M
6020	3	Mike	Burns	14	9	1970	M
17037	4	Cle	Kooiman	4	7	1963	M
8863	5	Thomas	Dooley	5	12	1961	M
85613	7	Hugo	Pérez	8	11	1963	M
96178	8	Earnie	Stewart	28	3	1969	M
69356	10	Roy	Wegerle	19	3	1964	M
83591	12	Juergen	Sommer	27	2	1969	M
49258	13	Cobi	Jones	16	6	1970	M
77685	14	Frank	Klopas	1	9	1966	M
86464	15	Joe-Max	Moore	23	2	1971	M
9412	16	Mike	Sorber	14	5	1971	M
76191	18	Brad	Friedel	18	5	1971	M
97459	19	Claudio	Reyna	20	7	1973	M
34393	21	Fernando	Clavijo	23	1	1956	M
79863	22	Alexi	Lalas	1	6	1970	M
59523	1	Tracey	Wheeler	26	9	1967	F
36187	2	Sarah	Cooper	8	10	1969	F
62503	3	Jane	Oakley	25	6	1966	F
61821	4	Julie	Murray	28	4	1970	F
19145	5	Cheryl	Salisbury	8	3	1974	F
46124	6	Anissa	Tann	10	10	1967	F
77926	7	Alison	Forman	17	3	1969	F
17776	8	Sonia	Gegenhuber	28	9	1970	F
72800	9	Angela	Iannotta	22	3	1971	F
11465	10	Sunni	Hughes	6	9	1968	F
56286	11	Kaylene	Janssen	18	8	1968	F
41263	12	Michelle	Watson	17	6	1976	F
1955	13	Traci	Bartlett	17	5	1972	F
48797	14	Denie	Pentecost	23	4	1970	F
87217	15	Kim	Lembryk	19	2	1966	F
98447	16	Lisa	Casagrande	29	5	1978	F
30671	17	Sacha	Wainwright	6	2	1972	F
85660	18	Louise	McMurtrie	26	4	1976	F
78673	19	Lizzy	Claydon	11	11	1972	F
97196	20	Claire	Nichols	7	8	1975	F
27861	2	not applicable	Valeria	9	3	1968	F
97167	5	Leda	Maria	16	4	1966	F
14897	9	Michael	Jackson	19	11	1963	F
57452	10	not applicable	Sissi	2	6	1967	F
9559	12	not applicable	Eliane	22	4	1971	F
9127	13	not applicable	Nenê	31	3	1976	F
19610	16	not applicable	Formiga	3	3	1978	F
57230	17	not applicable	Yara	13	2	1964	F
90420	18	not applicable	Kátia	18	2	1977	F
40008	19	not applicable	Suzy	2	7	1967	F
10543	20	not applicable	Tânia	10	3	1974	F
71792	1	Wendy	Hawthorne	6	7	1960	F
89408	2	Helen	Stoumbos	18	10	1970	F
26057	3	Charmaine	Hooper	15	1	1968	F
39552	4	Michelle	Ring	28	11	1967	F
87255	5	Andrea	Neil	26	10	1971	F
28260	6	Geri	Donnelly	30	11	1965	F
39878	7	Isabelle	Morneau	18	4	1976	F
27736	8	Nicole	Sedgwick	19	1	1974	F
76622	9	Janine	Helland	24	4	1970	F
96858	10	Veronica	O'Brien	29	1	1971	F
87029	11	Annie	Caron	5	6	1964	F
52120	12	Joan	McEachern	4	12	1963	F
57996	13	Angela	Kelly	10	3	1971	F
40501	14	Cathy	Ross	19	11	1967	F
36143	15	Suzanne	Muir	6	7	1970	F
62330	16	Luce	Mongrain	1	11	1971	F
8594	17	Silvana	Burtini	10	5	1969	F
51170	18	Carla	Chin	5	10	1966	F
3186	19	Suzanne	Gerrior	4	4	1973	F
91403	20	Tania	Singfield	9	2	1970	F
44067	2	Liping	Wang	12	11	1973	F
36217	3	Yunjie	Fan	29	4	1972	F
17198	4	Hongqi	Yu	2	2	1973	F
46333	14	Huilin	Xie	17	1	1975	F
35093	15	Guihong	Shi	13	2	1968	F
51755	16	Yufeng	Chen	17	1	1970	F
65910	17	Lihong	Zhao	25	12	1972	F
94408	18	Yanling	Man	9	11	1972	F
95666	19	Ying	Li	21	10	1973	F
75180	20	Hong	Gao	27	11	1967	F
80982	1	Dorthe	Larsen	8	8	1969	F
56909	2	Louise	Hansen	4	5	1975	F
22662	3	Kamma	Flæng	30	3	1976	F
91633	4	Lene	Terp	15	4	1973	F
80373	5	Katrine	Pedersen	13	4	1977	F
4853	7	Annette	Laursen	6	2	1975	F
26680	10	Birgit	Christensen	31	5	1976	F
93175	11	Gitte	Krogh	13	5	1977	F
71560	12	Anne Dot	Eggers Nielsen	6	11	1975	F
89851	13	Christina	Hansen	5	6	1970	F
49236	14	Lene	Madsen	11	3	1973	F
6433	15	Christina	Bonde	28	9	1973	F
73990	17	Karina	Christensen	1	7	1973	F
45540	18	Bettina	Allentoft	16	11	1973	F
61320	19	Jeanne	Axelsen	3	1	1968	F
47392	20	Christina	Petersen	17	9	1974	F
95119	1	Pauline	Cope	16	2	1969	F
53455	2	Hope	Powell	8	12	1966	F
78636	3	Tina	Mapes	21	1	1971	F
10209	4	Samantha	Britton	8	12	1973	F
99203	5	Clare	Taylor	22	5	1965	F
85614	6	Gillian	Coultard	22	7	1963	F
63458	7	Marieanne	Spacey	13	2	1966	F
41909	8	Debbie	Bampton	7	10	1961	F
19148	9	Karen	Farley	2	9	1970	F
7772	10	Karen	Burke	14	6	1971	F
74331	11	Brenda	Sempare	9	11	1961	F
3911	12	Kerry	Davis	8	2	1962	F
33331	13	Lesley	Higgs	25	10	1965	F
84117	14	Karen	Walker	29	7	1969	F
70273	15	Sian	Williams	2	2	1968	F
68761	16	Donna	Smith	17	1	1967	F
25880	17	Louise	Waller	30	7	1969	F
98782	18	Mary	Phillip	14	3	1977	F
30070	19	Julie	Fletcher	28	9	1974	F
17606	20	Becky	Easton	16	4	1974	F
99286	1	Manuela	Goller	5	1	1971	F
27293	2	Anouschka	Bernhard	5	10	1970	F
2008	4	Dagmar	Pohlmann	7	2	1972	F
78183	5	Ursula	Lohn	7	11	1966	F
50598	6	Maren	Meinert	5	8	1973	F
53623	11	Patricia	Brocker	7	4	1966	F
67353	12	Katja	Kraus	23	11	1970	F
61679	13	Melanie	Hoffmann	29	11	1974	F
53205	14	Sandra	Minnert	7	4	1973	F
84207	15	Claudia	Klein	24	9	1971	F
52478	16	Birgit	Prinz	25	10	1977	F
33252	17	Tina	Wunderlich	10	10	1977	F
8789	18	Pia	Wunderlich	26	1	1975	F
49074	19	Sandra	Smisek	3	7	1977	F
9165	20	Christine	Francke	12	6	1974	F
98768	1	Junko	Ozawa	12	7	1973	F
78173	2	Yumi	Tomei	1	6	1972	F
62310	3	Rie	Yamaki	2	10	1975	F
58567	4	Maki	Haneta	30	9	1972	F
26393	5	Ryoko	Uno	11	9	1975	F
69979	6	Kae	Nishina	7	12	1972	F
72113	7	Homare	Sawa	6	9	1978	F
70955	14	Kaoru	Kadohara	25	5	1970	F
10900	15	Tsuru	Morimoto	9	11	1970	F
82283	16	Nami	Otake	30	7	1974	F
15690	18	Inesu Emiko	Takeoka	1	5	1971	F
57497	19	Shiho	Onodera	18	11	1973	F
85817	6	Yinka	Kudaisi	25	8	1975	F
65870	11	Prisca	Emeafu	30	3	1972	F
93242	12	Mercy	Akide	26	8	1975	F
94567	15	Maureen	Mmadu	7	5	1975	F
40837	16	Ugochi	Opara	27	5	1976	F
38185	17	Louisa	Akpagu	22	12	1974	F
10791	18	Patience	Avre	10	6	1976	F
5714	4	Anne	Nymark Andersen	28	9	1972	F
29154	5	Nina	Nymark Andersen	28	9	1972	F
84049	9	Kristin	Sandberg	23	3	1972	F
29915	11	Ann Kristin	Aarønes	19	1	1973	F
33146	13	Merete	Myklebust	16	5	1973	F
22200	14	Hege	Gunnerød	22	11	1973	F
79792	15	Randi	Leinan	9	4	1968	F
75121	16	Marianne	Pettersen	12	4	1975	F
10394	17	Anita	Waage	31	7	1971	F
98852	18	Tone Gunn	Frustøl	21	6	1975	F
5474	20	Ingrid	Sternhoff	25	2	1977	F
11793	3	Åsa	Jakobsson	2	6	1966	F
26509	5	Kristin	Bengtsson	12	1	1970	F
90709	6	Anna	Pohjanen	25	1	1974	F
97773	9	Malin	Andersson	4	5	1973	F
87263	11	Ulrika	Kalte	19	5	1970	F
86300	12	Annelie	Nilsson	14	6	1971	F
82426	13	Annika	Nessvold	24	2	1971	F
24285	14	Åsa	Lönnqvist	14	4	1970	F
84497	15	Anneli	Olsson	7	2	1967	F
23090	17	Malin	Flink	4	9	1974	F
90074	19	Anika	Bozicevic	8	11	1972	F
17354	20	Sofia	Johansson	5	9	1969	F
17759	1	Briana	Scurry	7	9	1971	F
39237	2	Thori	Staples	17	4	1974	F
73318	3	Holly	Manthei	8	2	1976	F
75727	5	Tiffany	Roberts	5	5	1977	F
78370	6	Debbie	Keller	24	3	1975	F
57583	7	Sarah	Rafanelli	7	6	1972	F
49668	15	Tisha	Venturini	3	3	1973	F
98699	16	Tiffeny	Milbrett	23	10	1972	F
47474	17	Jennifer	Lalor	5	9	1974	F
38343	18	Saskia	Webber	13	6	1971	F
57965	19	Amanda	Cromwell	15	6	1970	F
81085	1	Carlos	Roa	15	8	1969	M
83403	2	Roberto	Ayala	14	4	1973	M
28597	4	Mauricio	Pineda	13	7	1975	M
88203	5	Matías	Almeyda	21	12	1973	M
60203	7	Claudio	López	17	7	1974	M
62209	11	Juan Sebastián	Verón	9	3	1975	M
56385	12	Germán	Burgos	16	4	1969	M
43717	13	Pablo	Paz	27	1	1973	M
65019	14	Nelson	Vivas	18	10	1969	M
67181	15	Leonardo	Astrada	6	1	1970	M
70099	16	Sergio	Berti	17	9	1969	M
60052	17	Pablo	Cavallero	13	4	1974	M
19888	19	Hernán	Crespo	5	7	1975	M
94002	20	Marcelo	Gallardo	18	1	1976	M
45030	21	Marcelo	Delgado	24	3	1973	M
53716	22	Javier	Zanetti	10	8	1973	M
78149	2	Markus	Schopp	22	2	1974	M
77565	5	Wolfgang	Feiersinger	30	1	1965	M
10661	6	Walter	Kogler	12	12	1967	M
29966	7	Mario	Haas	16	9	1974	M
28521	9	Ivica	Vastić	29	9	1969	M
31537	11	Martin	Amerhauser	23	7	1974	M
61823	12	Martin	Hiden	11	3	1973	M
99116	13	Harald	Cerny	13	9	1973	M
66639	14	Hannes	Reinmayr	23	8	1969	M
9345	15	Arnold	Wetl	2	2	1970	M
18786	16	Franz	Wohlfahrt	1	7	1964	M
87315	17	Roman	Mählich	17	9	1971	M
63420	18	Peter	Stöger	11	4	1966	M
62915	20	Andreas	Heraf	10	9	1967	M
68074	21	Wolfgang	Knaller	9	10	1961	M
37008	22	Dietmar	Kühbauer	4	4	1971	M
12959	2	Bertrand	Crasson	5	10	1971	M
86884	4	Gordan	Vidović	23	6	1968	M
109	8	Luís	Oliveira	24	3	1969	M
90633	9	Mbo	Mpenza	4	12	1976	M
28883	11	Nico	Van Kerckhoven	14	12	1970	M
18623	12	Philippe	Vande Walle	22	12	1961	M
15154	15	Philippe	Clement	22	3	1974	M
94736	16	Glen	De Boeck	22	8	1971	M
39573	17	Mike	Verstraeten	12	8	1967	M
52358	18	Gert	Verheyen	20	9	1970	M
1706	20	Émile	Mpenza	4	7	1978	M
17071	22	Éric	Deflandre	2	8	1973	M
9547	4	Júnior	Baiano	14	3	1970	M
3658	5	César	Sampaio	31	3	1968	M
85176	6	Roberto	Carlos	10	4	1973	M
10812	7	not applicable	Giovanni	4	2	1972	M
74261	10	not applicable	Rivaldo	19	4	1972	M
52008	11	not applicable	Emerson	4	4	1976	M
70594	12	Carlos	Germano	14	8	1970	M
63053	13	not applicable	Zé Carlos	14	11	1968	M
93839	14	not applicable	Gonçalves	22	2	1966	M
99966	15	André	Cruz	20	9	1968	M
39545	16	not applicable	Zé Roberto	6	7	1974	M
64142	17	not applicable	Doriva	28	5	1972	M
79146	19	not applicable	Denílson	24	8	1977	M
24526	21	not applicable	Edmundo	2	4	1971	M
2795	22	not applicable	Dida	7	10	1973	M
39700	1	Zdravko	Zdravkov	4	10	1970	M
14982	2	Radostin	Kishishev	30	7	1974	M
84375	4	Ivaylo	Petkov	24	3	1976	M
99418	9	Lyuboslav	Penev	31	8	1966	M
57696	11	Ilian	Iliev	2	7	1968	M
11736	13	Gosho	Ginchev	2	12	1969	M
28549	14	Marian	Hristov	29	7	1973	M
1256	15	Adalbert	Zafirov	29	9	1969	M
16713	16	Anatoli	Nankov	15	7	1969	M
5818	17	Stoycho	Stoilov	15	10	1971	M
41316	19	Georgi	Bachev	18	4	1977	M
67598	20	Georgi	Ivanov	2	7	1976	M
26718	21	Rosen	Kirilov	4	1	1973	M
25506	22	Milen	Petkov	12	1	1974	M
97878	2	Joseph	Elanga	2	5	1979	M
67168	3	Pierre	Womé	26	3	1979	M
53197	6	Pierre	Njanka	15	3	1975	M
6511	8	Didier	Angibeaud	8	10	1974	M
18804	10	Patrick	M'Boma	15	11	1970	M
61703	11	Samuel	Eto'o	10	3	1981	M
38724	12	not applicable	Lauren	19	1	1977	M
35138	13	Patrice	Abanda	3	8	1978	M
33623	14	Augustine	Simo	18	9	1978	M
78387	15	Joseph	N'Do	28	4	1976	M
44460	16	William	Andem	14	6	1968	M
7577	17	Michel	Pensée	16	6	1973	M
45873	18	Samuel	Ipoua	1	3	1973	M
87968	19	Marcel	Mahouvé	16	1	1973	M
84152	20	Salomon	Olembé	8	12	1980	M
14458	21	Joseph-Désiré	Job	1	12	1977	M
41783	22	Alioum	Boukar	3	1	1972	M
26025	1	Nelson	Tapia	22	9	1966	M
85132	2	Cristián	Castañeda	18	9	1968	M
80753	3	Ronald	Fuentes	22	6	1969	M
79494	4	Francisco	Rojas	22	7	1974	M
8453	5	Javier	Margas	10	5	1969	M
49850	6	Pedro	Reyes	13	11	1972	M
91710	7	Nelson	Parraguez	5	4	1971	M
43934	8	Clarence	Acuña	8	2	1975	M
82614	9	Iván	Zamorano	18	1	1967	M
85178	10	José Luis	Sierra	5	12	1968	M
39251	11	Marcelo	Salas	24	12	1974	M
61561	12	Marcelo	Ramírez	29	5	1965	M
15650	13	Manuel	Neira	12	10	1977	M
30572	14	Miguel	Ramírez	11	6	1970	M
16244	15	Moisés	Villarroel	12	2	1976	M
84458	16	Mauricio	Aros	9	3	1976	M
56057	17	Marcelo	Vega	12	8	1971	M
51514	18	Luis	Musrri	24	12	1969	M
76038	19	Fernando	Cornejo	28	1	1969	M
14852	20	Fabián	Estay	5	10	1968	M
20330	21	Rodrigo	Barrera	30	3	1970	M
74519	22	Carlos	Tejas	4	10	1974	M
9175	2	Iván	Córdoba	11	8	1976	M
848	3	Ever	Palacios	18	1	1969	M
21571	4	José	Santa	12	11	1970	M
71020	5	Jorge	Bermúdez	18	6	1971	M
18252	12	Miguel	Calero	14	4	1971	M
77800	14	Jorge	Bolaño	28	4	1977	M
75570	16	Luis Antonio	Moreno	25	12	1970	M
522	17	Andrés	Estrada	12	11	1967	M
51932	18	John Wilmar	Pérez	2	2	1970	M
30514	20	Hámilton	Ricard	12	1	1974	M
64415	21	Léider	Preciado	26	2	1977	M
52310	1	Dražen	Ladić	1	1	1963	M
43142	2	Petar	Krpan	1	7	1974	M
31857	3	Anthony	Šerić	15	1	1979	M
98512	4	Igor	Štimac	6	9	1967	M
44332	5	Goran	Jurić	5	2	1963	M
85355	6	Slaven	Bilić	11	9	1968	M
21803	7	Aljoša	Asanović	14	12	1965	M
5779	10	Zvonimir	Boban	8	10	1968	M
18926	11	Silvio	Marić	20	3	1975	M
96358	12	Marjan	Mrmić	6	5	1965	M
75377	13	Mario	Stanić	10	4	1972	M
37461	14	Zvonimir	Soldo	2	11	1967	M
42144	15	Igor	Tudor	16	4	1978	M
93377	16	Ardian	Kozniku	27	10	1967	M
59881	18	Zoran	Mamić	30	9	1971	M
96110	19	Goran	Vlaović	7	8	1972	M
41724	20	Dario	Šimić	12	11	1975	M
76217	21	Krunoslav	Jurčić	26	11	1969	M
94668	22	Vladimir	Vasilj	6	7	1975	M
35183	1	Peter	Schmeichel	18	11	1963	M
57898	2	Michael	Schjønberg	19	1	1967	M
77711	3	Marc	Rieper	5	6	1968	M
11000	4	Jes	Høgh	7	5	1966	M
79273	5	Jan	Heintze	17	8	1963	M
72404	6	Thomas	Helveg	24	6	1971	M
62564	7	Allan	Nielsen	13	3	1971	M
2695	8	Per	Frandsen	6	2	1970	M
75330	9	Miklos	Molnar	10	4	1970	M
28133	11	Brian	Laudrup	22	2	1969	M
90473	12	Søren	Colding	2	9	1972	M
1514	13	Jacob	Laursen	6	10	1971	M
87412	14	Morten	Wieghorst	25	2	1971	M
37132	15	Stig	Tøfting	14	8	1969	M
66859	16	Mogens	Krogh	31	10	1963	M
4448	17	Bjarne	Goldbæk	6	10	1968	M
87668	18	Peter	Møller	23	3	1972	M
80289	19	Ebbe	Sand	19	7	1972	M
86345	20	René	Henriksen	27	8	1969	M
68055	21	Martin	Jørgensen	6	10	1975	M
25541	22	Peter	Kjær	5	11	1965	M
97840	2	Sol	Campbell	18	9	1974	M
26320	3	Graeme	Le Saux	17	10	1968	M
15550	4	Paul	Ince	21	10	1967	M
54003	5	Tony	Adams	10	10	1966	M
79943	6	Gareth	Southgate	3	9	1970	M
81049	7	David	Beckham	2	5	1975	M
92367	8	David	Batty	2	12	1968	M
63416	9	Alan	Shearer	13	8	1970	M
94825	10	Teddy	Sheringham	2	4	1966	M
3532	11	Steve	McManaman	11	2	1972	M
66658	12	Gary	Neville	18	2	1975	M
93674	13	Nigel	Martyn	11	8	1966	M
40570	14	Darren	Anderton	3	3	1972	M
69168	15	Paul	Merson	20	3	1968	M
63916	16	Paul	Scholes	16	11	1974	M
43959	17	Rob	Lee	1	2	1966	M
90384	18	Martin	Keown	24	7	1966	M
89205	19	Les	Ferdinand	8	12	1966	M
51130	20	Michael	Owen	14	12	1979	M
1249	21	Rio	Ferdinand	7	11	1978	M
61105	22	Tim	Flowers	3	2	1967	M
30371	1	Bernard	Lama	7	4	1963	M
22876	2	Vincent	Candela	24	10	1973	M
56735	3	Bixente	Lizarazu	9	12	1969	M
96540	4	Patrick	Vieira	23	6	1976	M
74952	5	Laurent	Blanc	19	11	1965	M
80680	6	Youri	Djorkaeff	9	3	1968	M
61954	7	Didier	Deschamps	15	10	1968	M
79380	8	Marcel	Desailly	7	9	1968	M
26820	9	Stéphane	Guivarc'h	6	9	1970	M
56430	10	Zinedine	Zidane	23	6	1972	M
99420	11	Robert	Pires	29	10	1973	M
51395	12	Thierry	Henry	17	8	1977	M
54985	13	Bernard	Diomède	23	1	1974	M
10738	14	Alain	Boghossian	27	10	1970	M
56947	15	Lilian	Thuram	1	1	1972	M
55991	16	Fabien	Barthez	28	6	1971	M
40400	17	Emmanuel	Petit	22	9	1970	M
19907	18	Frank	Leboeuf	22	1	1968	M
28482	19	Christian	Karembeu	3	12	1970	M
12167	20	David	Trezeguet	15	10	1977	M
74065	21	Christophe	Dugarry	24	3	1972	M
75179	22	Lionel	Charbonnier	25	10	1966	M
53262	2	Christian	Wörns	10	5	1972	M
78998	3	Jörg	Heinrich	6	12	1969	M
62028	11	Olaf	Marschall	19	3	1966	M
65108	13	Jens	Jeremies	5	3	1974	M
83522	14	Markus	Babbel	8	9	1972	M
94904	15	Steffen	Freund	19	1	1970	M
35902	16	Dietmar	Hamann	27	8	1973	M
67544	17	Christian	Ziege	1	2	1972	M
84534	20	Oliver	Bierhoff	1	5	1968	M
15678	21	Michael	Tarnat	27	10	1969	M
98511	22	Jens	Lehmann	10	11	1969	M
56772	1	Ahmad Reza	Abedzadeh	25	5	1966	M
93633	2	Mehdi	Mahdavikia	24	7	1977	M
36676	3	Naeim	Saadavi	16	6	1969	M
52257	4	Mohammad	Khakpour	20	2	1969	M
91754	5	Afshin	Peyrovani	6	2	1970	M
72482	6	Karim	Bagheri	20	2	1974	M
62874	7	Alireza	Mansourian	12	12	1971	M
44661	8	Sirous	Dinmohammadi	2	7	1970	M
78085	9	Hamid	Estili	1	4	1967	M
38371	10	Ali	Daei	21	3	1969	M
25470	11	Khodadad	Azizi	22	6	1971	M
68937	12	Nima	Nakisa	1	5	1975	M
54946	13	Ali	Latifi	20	2	1976	M
31741	14	Nader	Mohammadkhani	23	8	1963	M
55250	15	Ali Akbar	Ostad-Asadi	17	9	1965	M
92960	16	Reza	Shahroudi	21	2	1972	M
65077	17	Javad	Zarincheh	23	7	1966	M
90057	18	Sattar	Hamedani	6	6	1974	M
11493	19	Behnam	Seraj	19	6	1971	M
6693	20	Mehdi	Pashazadeh	27	12	1973	M
32369	21	Mehrdad	Minavand	30	11	1975	M
315	22	Parviz	Boroumand	11	9	1972	M
53723	1	Francesco	Toldo	2	12	1971	M
88863	4	Fabio	Cannavaro	13	9	1973	M
55511	6	Alessandro	Nesta	19	3	1976	M
74039	7	Gianluca	Pessotto	11	8	1970	M
39112	8	Moreno	Torricelli	23	1	1970	M
83836	10	Alessandro	Del Piero	9	11	1974	M
98757	13	Sandro	Cois	9	6	1972	M
42659	14	Luigi	Di Biagio	3	6	1971	M
59777	15	Angelo	Di Livio	26	7	1966	M
7951	16	Roberto	Di Matteo	29	5	1970	M
69680	17	Francesco	Moriero	31	3	1969	M
29172	19	Filippo	Inzaghi	9	8	1973	M
35079	20	Enrico	Chiesa	29	12	1970	M
34670	21	Christian	Vieri	12	7	1973	M
11392	22	Gianluigi	Buffon	28	1	1978	M
65816	1	Warren	Barrett	9	7	1970	M
6565	2	Stephen	Malcolm	2	5	1970	M
61134	3	Chris	Dawes	31	5	1974	M
40167	4	Linval	Dixon	14	9	1971	M
51917	5	Ian	Goodison	21	11	1972	M
62344	6	Fitzroy	Simpson	26	2	1970	M
49195	7	Peter	Cargill	2	3	1964	M
44917	8	Marcus	Gayle	27	9	1970	M
45682	9	Andy	Williams	23	9	1977	M
97544	10	Walter	Boyd	1	1	1972	M
19136	11	Theodore	Whitmore	5	8	1972	M
93008	12	Dean	Sewell	13	4	1972	M
98909	13	Aaron	Lawrence	11	8	1970	M
99080	14	Donovan	Ricketts	7	6	1977	M
79750	15	Ricardo	Gardner	25	9	1978	M
16421	16	Robbie	Earle	27	1	1965	M
89092	17	Onandi	Lowe	2	12	1973	M
36985	18	Deon	Burton	25	10	1976	M
99905	19	Frank	Sinclair	3	12	1971	M
41974	20	Darryl	Powell	15	11	1971	M
27847	21	Durrant	Brown	8	7	1964	M
15931	22	Paul	Hall	3	7	1972	M
2366	1	Nobuyuki	Kojima	17	1	1966	M
45752	2	Akira	Narahashi	26	11	1971	M
61672	3	Naoki	Soma	19	7	1971	M
29629	4	Masami	Ihara	18	9	1967	M
43163	5	Norio	Omura	6	9	1969	M
3376	6	Motohiro	Yamaguchi	29	1	1969	M
23890	7	Teruyoshi	Ito	31	8	1974	M
9349	8	Hidetoshi	Nakata	22	1	1977	M
84762	9	Masashi	Nakayama	23	9	1967	M
33594	10	Hiroshi	Nanami	28	11	1972	M
4785	11	Shinji	Ono	27	9	1979	M
58318	12	Wagner	Lopes	29	1	1969	M
64961	13	Toshihiro	Hattori	23	9	1973	M
7585	14	Masayuki	Okano	25	7	1972	M
17348	15	Hiroaki	Morishima	30	4	1972	M
10510	16	Toshihide	Saito	20	4	1973	M
34956	17	Yutaka	Akita	6	8	1970	M
55311	18	Shoji	Jo	17	6	1975	M
36022	19	Eisuke	Nakanishi	23	6	1973	M
54298	20	Yoshikatsu	Kawaguchi	15	8	1975	M
24251	21	Seigo	Narazaki	15	4	1976	M
99803	22	Takashi	Hirano	15	7	1974	M
26108	3	Joel	Sánchez	17	8	1974	M
72763	4	Germán	Villa	2	4	1973	M
83344	5	Duilio	Davino	21	3	1976	M
50252	9	Ricardo	Peláez	14	3	1963	M
88428	11	Cuauhtémoc	Blanco	17	1	1973	M
92932	12	Oswaldo	Sánchez	21	9	1973	M
34636	13	Pável	Pardo	26	7	1976	M
35791	14	Raúl	Lara	28	2	1973	M
45941	15	Luis	Hernández	22	12	1968	M
99771	16	Isaac	Terrazas	17	4	1975	M
80183	17	Francisco	Palencia	28	4	1973	M
32594	18	Salvador	Carmona	22	8	1975	M
19578	19	Braulio	Luna	8	9	1974	M
77010	20	Jaime	Ordiales	23	12	1963	M
92547	21	Jesús	Arellano	8	5	1973	M
52784	22	Óscar	Pérez	1	2	1973	M
62026	1	Abdelkader	El Brazi	5	11	1964	M
16954	2	Abdelilah	Saber	21	4	1974	M
66082	4	Youssef	Rossi	28	6	1973	M
76158	8	Saïd	Chiba	18	9	1970	M
14349	9	Abdeljalil	Hadda	21	3	1972	M
56643	10	Abderrahim	Ouakili	11	12	1970	M
80057	11	Ali	Elkhattabi	17	1	1977	M
20094	12	Driss	Benzekri	31	12	1970	M
87059	14	Salaheddine	Bassir	5	9	1972	M
51300	15	Lahcen	Abrami	31	12	1969	M
28649	17	Gharib	Amzine	3	5	1973	M
78077	18	Youssef	Chippo	10	5	1973	M
32237	19	Jamal	Sellami	6	10	1970	M
3706	21	Rachid	Rokki	8	11	1974	M
89078	22	Mustapha	Chadili	14	2	1973	M
27926	2	Michael	Reiziger	3	5	1973	M
46061	3	Jaap	Stam	17	7	1972	M
59191	9	Patrick	Kluivert	1	7	1976	M
88946	10	Clarence	Seedorf	1	4	1976	M
42224	11	Phillip	Cocu	29	10	1970	M
34767	12	Boudewijn	Zenden	15	8	1976	M
96131	13	André	Ooijer	11	7	1974	M
76156	15	Winston	Bogarde	22	10	1970	M
45916	16	Edgar	Davids	13	3	1973	M
88340	17	Pierre	van Hooijdonk	29	11	1969	M
21832	19	Giovanni	van Bronckhorst	5	2	1975	M
30015	21	Jimmy Floyd	Hasselbaink	27	3	1972	M
55197	22	Ruud	Hesp	31	10	1965	M
1364	2	Mobi	Oparaku	1	12	1976	M
91148	3	Celestine	Babayaro	29	8	1978	M
91516	4	Nwankwo	Kanu	1	8	1976	M
79669	6	Taribo	West	26	3	1974	M
76542	11	Garba	Lawal	22	5	1974	M
79585	12	Willy	Okpara	7	5	1968	M
2360	13	Tijani	Babangida	25	9	1973	M
89782	18	Wilson	Oruma	30	12	1976	M
71220	21	Godwin	Okpara	20	9	1972	M
35031	22	Abiodun	Baruwa	16	11	1974	M
65348	3	Ronny	Johnsen	10	6	1969	M
75062	6	Ståle	Solbakken	27	2	1968	M
3442	9	Tore André	Flo	15	6	1973	M
99616	12	Thomas	Myhre	16	10	1973	M
31312	13	Espen	Baardsen	7	12	1977	M
86211	14	Vegard	Heggem	13	7	1975	M
99732	17	Håvard	Flo	4	4	1970	M
94822	18	Egil	Østenstad	2	1	1972	M
25187	19	Erik	Hoftun	3	3	1969	M
63924	20	Ole Gunnar	Solskjær	26	2	1973	M
35373	21	Vidar	Riseth	21	4	1972	M
36426	1	José Luis	Chilavert	27	7	1965	M
76678	2	Francisco	Arce	2	4	1971	M
14942	3	Catalino	Rivarola	30	4	1965	M
19241	4	Carlos	Gamarra	17	2	1971	M
34957	5	Celso	Ayala	20	8	1970	M
11212	6	Edgar	Aguilera	28	7	1975	M
74664	7	Julio César	Yegros	31	1	1971	M
3217	8	Arístides	Rojas	12	8	1968	M
98051	9	José	Cardozo	19	3	1971	M
17884	10	Roberto	Acuña	25	3	1972	M
50567	11	Pedro	Sarabia	5	7	1975	M
75402	12	Danilo	Aceval	15	9	1975	M
42797	13	Carlos	Paredes	16	7	1976	M
8196	14	Ricardo	Rojas	26	1	1971	M
40108	15	Miguel Ángel	Benítez	19	5	1970	M
52469	16	Julio César	Enciso	5	8	1974	M
73933	17	Hugo	Brizuela	8	2	1969	M
34676	18	César	Ramírez	21	3	1977	M
22146	19	Carlos	Morales	4	11	1968	M
82458	20	Denis	Caniza	29	8	1974	M
78557	21	Jorge Luis	Campos	11	8	1970	M
83261	22	Rubén	Ruiz Díaz	11	11	1969	M
75836	1	Dumitru	Stângaciu	9	8	1964	M
65453	3	Cristian	Dulca	25	9	1972	M
6854	4	Anton	Doboș	13	10	1965	M
70680	11	Adrian	Ilie	20	4	1974	M
16780	13	Liviu	Ciobotariu	26	3	1971	M
27750	14	Radu	Niculescu	2	3	1975	M
66588	15	Lucian	Marinescu	24	6	1972	M
53546	16	Gabriel	Popescu	23	12	1973	M
48638	18	Iulian	Filipescu	29	3	1974	M
43055	21	Gheorghe	Craioveanu	14	2	1968	M
55518	2	Mohammed	Al-Jahani	28	9	1974	M
92151	7	Ibrahim	Al-Shahrani	21	7	1974	M
85019	8	Obeid	Al-Dosari	2	10	1975	M
81321	12	Ibrahim	Al-Harbi	10	7	1975	M
73110	13	Hussein	Abdulghani	23	1	1977	M
30161	15	Yousuf	Al-Thunayan	18	11	1963	M
17941	16	Khamis	Al-Dosari	8	9	1973	M
53448	17	Ahmed	Al-Dokhi	25	10	1976	M
20886	18	Nawaf	Al-Temyat	28	6	1976	M
28313	19	Abdulaziz	Al-Janoubi	21	7	1974	M
45367	22	Tisir	Al-Antaif	16	2	1974	M
95707	2	Jackie	McNamara	24	10	1973	M
48864	3	Tom	Boyd	24	11	1965	M
77029	4	Colin	Calderwood	20	1	1965	M
68779	5	Colin	Hendry	7	12	1965	M
39255	6	Tosh	McKinlay	3	12	1964	M
189	7	Kevin	Gallacher	23	11	1966	M
74264	8	Craig	Burley	24	9	1971	M
56227	10	Darren	Jackson	25	7	1966	M
28281	12	Neil	Sullivan	24	2	1970	M
25813	13	Simon	Donnelly	1	12	1974	M
30400	14	Paul	Lambert	7	8	1969	M
85724	15	Scot	Gemmill	2	1	1971	M
96166	16	David	Weir	10	5	1970	M
2421	17	Billy	McKinlay	22	4	1969	M
14701	18	Matt	Elliott	1	11	1968	M
54290	19	Derek	Whyte	31	8	1968	M
51888	20	Scott	Booth	16	12	1971	M
1355	21	Jonathan	Gould	18	7	1968	M
60841	22	Christian	Dailly	23	10	1973	M
57626	1	Hans	Vonk	30	1	1970	M
28712	2	Themba	Mnguni	16	12	1973	M
10490	3	David	Nyathi	22	3	1969	M
94478	4	Willem	Jackson	26	3	1972	M
92802	5	Mark	Fish	14	3	1974	M
5915	6	Phil	Masinga	28	6	1969	M
2423	7	Quinton	Fortune	21	5	1977	M
19030	8	Alfred	Phiri	22	6	1974	M
24299	9	Shaun	Bartlett	31	10	1972	M
85624	10	John	Moshoeu	18	12	1965	M
88704	11	Helman	Mkhalele	20	10	1969	M
45250	12	Brendan	Augustine	26	10	1971	M
37844	13	Delron	Buckley	7	12	1977	M
32294	14	Jerry	Sikhosana	8	6	1969	M
47572	15	Doctor	Khumalo	26	6	1967	M
16070	16	Brian	Baloyi	16	3	1974	M
59298	17	Benni	McCarthy	12	11	1977	M
85237	18	Lebogang	Morula	22	12	1968	M
56543	19	Lucas	Radebe	12	4	1969	M
54426	20	William	Mokoena	31	3	1975	M
65806	21	Pierre	Issa	12	9	1975	M
97369	22	Paul	Evans	28	12	1973	M
83595	23	Simon	Gopane	26	12	1970	M
84722	1	Byung-ji	Kim	8	4	1970	M
17666	2	Sung-yong	Choi	25	12	1975	M
65241	3	Lim-saeng	Lee	18	11	1971	M
66219	5	Min-sung	Lee	23	6	1973	M
75255	6	Sang-chul	Yoo	18	10	1971	M
54653	7	Do-keun	Kim	2	3	1972	M
2853	9	Do-hoon	Kim	21	7	1970	M
72495	10	Yong-soo	Choi	10	9	1973	M
54130	12	Sang-hun	Lee	11	10	1975	M
96267	13	Tae-young	Kim	8	11	1970	M
64624	14	Jong-soo	Ko	30	10	1978	M
64908	16	Hyung-seok	Jang	7	7	1972	M
75418	19	Dae-il	Jang	9	3	1975	M
85453	21	Dong-gook	Lee	29	4	1979	M
56801	22	Dong-myung	Seo	4	5	1974	M
60583	3	Agustín	Aranzábal	15	3	1973	M
8514	7	Fernando	Morientes	5	4	1976	M
75598	9	Juan Antonio	Pizzi	7	6	1968	M
24556	10	not applicable	Raúl	27	6	1977	M
34	11	not applicable	Alfonso	26	9	1972	M
22620	14	Iván	Campo	21	2	1974	M
8700	15	Carlos	Aguilera	22	5	1969	M
8262	16	Albert	Celades	29	9	1975	M
93745	17	Joseba	Etxeberria	5	9	1977	M
61706	18	Guillermo	Amor	4	12	1967	M
64962	19	not applicable	Kiko	26	4	1972	M
57289	22	José	Molina	8	8	1970	M
23480	1	Chokri	El Ouaer	15	8	1966	M
90120	2	Imed	Ben Younes	16	6	1974	M
73316	3	Sami	Trabelsi	4	2	1968	M
25497	4	Mounir	Boukadida	24	10	1967	M
82870	5	Hatem	Trabelsi	25	1	1977	M
48736	6	Ferid	Chouchane	19	4	1973	M
47506	7	Tarek	Thabet	16	8	1971	M
22242	8	Zoubeir	Baya	15	5	1971	M
89922	9	Riadh	Jelassi	7	7	1971	M
41620	10	Kaies	Ghodhbane	7	1	1976	M
15025	11	Adel	Sellimi	16	11	1972	M
668	12	Mourad	Melki	9	5	1975	M
89154	13	Riadh	Bouazizi	8	4	1973	M
28789	14	Sirajeddine	Chihi	16	4	1970	M
58711	15	Skander	Souayah	20	11	1972	M
12180	16	Radhouane	Salhi	18	12	1967	M
44011	17	José	Clayton	21	3	1974	M
88921	18	Mehdi	Ben Slimane	1	1	1974	M
49604	19	Faysal	Ben Ahmed	7	3	1973	M
16851	20	Sabri	Jaballah	28	6	1973	M
10094	21	Khaled	Badra	8	4	1973	M
52641	22	Ali	Boumnijel	13	4	1966	M
34695	2	Frankie	Hejduk	5	8	1974	M
2842	3	Eddie	Pope	24	12	1973	M
68379	6	David	Regis	2	12	1968	M
72797	12	Jeff	Agoos	2	5	1968	M
25779	14	Predrag	Radosavljević	24	6	1963	M
18539	15	Chad	Deering	2	9	1970	M
36074	19	Brian	Maisonneuve	28	6	1973	M
60597	20	Brian	McBride	19	6	1972	M
69448	1	Ivica	Kralj	26	3	1973	M
12268	2	Zoran	Mirković	21	9	1971	M
80898	3	Goran	Đorović	11	11	1971	M
27338	4	Slaviša	Jokanović	16	8	1968	M
72969	5	Miroslav	Đukić	19	2	1966	M
15547	6	Branko	Brnović	8	8	1967	M
69912	7	Vladimir	Jugović	30	8	1969	M
82329	9	Predrag	Mijatović	19	1	1969	M
4188	11	Siniša	Mihajlović	20	2	1969	M
43392	13	Slobodan	Komljenović	2	1	1971	M
35544	14	Niša	Saveljić	23	2	1970	M
57880	15	Ljubinko	Drulović	11	9	1968	M
11960	16	Željko	Petrović	13	11	1965	M
48250	17	Savo	Milošević	2	9	1973	M
40701	18	Dejan	Govedarica	2	10	1969	M
45323	19	Miroslav	Stević	7	1	1970	M
22793	20	Dejan	Stanković	11	9	1978	M
85140	21	Perica	Ognjenović	24	2	1977	M
33080	22	Darko	Kovačević	18	11	1973	M
70336	1	Belinda	Kitching	15	7	1977	F
99108	2	Amy	Taylor	11	6	1979	F
23968	3	Bridgette	Starr	10	12	1975	F
44064	11	Sharon	Black	4	4	1971	F
86048	12	Kristyn	Swaffer	13	12	1975	F
56574	13	Alicia	Ferguson	31	10	1981	F
4506	14	Joanne	Peters	11	3	1979	F
20570	15	Peita-Claire	Hepperlin	24	12	1981	F
75511	16	Amy	Wilson	9	6	1980	F
72006	17	Kelly	Golebiowski	26	7	1981	F
35111	19	Dianne	Alagich	12	5	1979	F
64203	1	not applicable	Maravilha	10	4	1973	F
96106	5	not applicable	Cidinha	6	10	1976	F
11872	6	not applicable	Juliana	3	10	1981	F
67574	7	not applicable	Maycon	30	4	1977	F
89410	11	not applicable	Suzana	12	10	1973	F
66036	12	not applicable	Andréia	14	9	1977	F
78266	14	not applicable	Grazielle	28	3	1981	F
89908	15	not applicable	Raquel	10	5	1978	F
58199	18	not applicable	Priscila	10	3	1982	F
62970	20	not applicable	Deva	16	4	1981	F
9794	1	Nicci	Wright	12	8	1972	F
76722	2	Liz	Smith	25	9	1975	F
50457	3	Sharolta	Nonen	30	12	1977	F
29054	4	Tanya	Franck	13	12	1974	F
56271	8	Sara	Maglio	17	3	1978	F
57254	11	Shannon	Rosenow	20	6	1972	F
97696	12	Isabelle	Harvey	27	3	1975	F
70567	13	Amy	Walsh	13	9	1977	F
73728	14	Sarah	Joly	16	2	1977	F
18666	16	Jeanette	Haas	3	1	1976	F
85899	18	Mary Beth	Bowie	27	10	1978	F
86965	19	Melanie	Haz	26	11	1975	F
41105	20	Karina	LeBlanc	30	3	1980	F
63535	1	Wenxia	Han	23	8	1976	F
70314	7	Ouying	Zhang	2	11	1975	F
9811	8	Yan	Jin	27	7	1972	F
67766	11	Wei	Pu	20	8	1980	F
48897	13	Ying	Liu	11	6	1974	F
16075	14	Jie	Bai	28	3	1972	F
84161	15	Haiyan	Qiu	17	6	1974	F
68281	16	Chunling	Fan	2	2	1972	F
20612	17	Jing	Zhu	2	3	1978	F
79018	19	Hongxia	Gao	7	12	1973	F
51393	20	Jingxia	Wang	11	11	1976	F
73900	2	Hanne	Sand Christensen	22	9	1973	F
74964	5	Marlene	Kristensen	28	5	1973	F
57369	11	Merete	Pedersen	30	6	1973	F
60476	12	Lene	Jensen	17	3	1976	F
37513	13	Ulla	Knudsen	21	6	1976	F
2005	15	Mikka	Hansen	11	11	1975	F
54677	16	Christina	Jensen	21	1	1974	F
20383	17	Hanne	Nørregaard	21	12	1968	F
64823	18	Lise	Søndergaard	27	10	1973	F
34416	19	Janni	Johansen	14	1	1976	F
81866	20	Anne-Mette	Christensen	4	3	1973	F
36668	1	Silke	Rottenberg	25	1	1972	F
27862	2	Kerstin	Stegemann	29	9	1977	F
78246	3	Ariane	Hingst	25	7	1979	F
70251	4	Steffi	Jones	22	12	1972	F
67283	12	Claudia	Müller	21	5	1974	F
54576	15	Nadine	Angerer	10	11	1978	F
42444	16	Renate	Lingor	11	10	1975	F
27479	18	Inka	Grings	31	10	1978	F
90924	19	Nicole	Brandebusemeyer	9	10	1974	F
73519	20	Monika	Meyer	23	6	1972	F
42042	1	Memunatu	Sulemana	4	11	1977	F
90753	2	Patience	Sackey	22	4	1975	F
44808	3	Rita	Yeboah	25	5	1976	F
21048	4	Regina	Ansah	23	8	1974	F
86407	5	Elizabeth	Baidu	28	4	1978	F
36715	6	Juliana	Kakraba	29	12	1979	F
14240	7	Mavis	Dgajmah	21	12	1973	F
78239	8	Barikisu	Tettey-Quao	28	8	1980	F
99818	9	Alberta	Sackey	6	11	1972	F
84231	10	Vivian	Mensah	13	6	1972	F
47674	11	Adjoa	Bayor	17	5	1979	F
89564	12	Kulu	Yahaya	23	5	1976	F
12997	13	Lydia	Ankrah	1	12	1973	F
52361	14	Mercy	Tagoe	5	2	1974	F
84404	15	Nana	Gyamfuah	4	8	1978	F
75315	16	Gladys	Enti	21	4	1975	F
54127	17	Sheila	Okai	14	2	1979	F
45660	18	Priscilla	Mensah	19	4	1974	F
90520	19	Stella	Quartey	28	12	1973	F
14601	20	Genevive	Clottey	25	4	1969	F
52348	2	Damiana	Deiana	26	6	1970	F
58574	3	Paola	Zanni	12	6	1977	F
62383	4	Luisa	Marchio	6	2	1971	F
67779	5	Daniela	Tavalazzi	8	8	1972	F
58581	6	Elisa	Miniati	6	1	1974	F
573	8	Manuela	Tesse	28	2	1976	F
6810	9	Patrizia	Panico	8	2	1975	F
49769	10	Antonella	Carta	1	3	1967	F
41283	11	Patrizia	Sberti	6	7	1969	F
13129	12	Fabiana	Comin	20	3	1970	F
30583	13	Anna	Duò	8	8	1972	F
47822	15	Adele	Frollani	4	8	1974	F
81336	16	Tatiana	Zorri	19	10	1977	F
11042	17	Silvia	Tagliacarne	8	8	1975	F
87749	19	Alessandra	Pallotti	7	9	1974	F
79263	20	Roberta	Stefanelli	18	5	1974	F
36151	3	Kaoru	Nagadome	7	5	1973	F
91945	4	Mai	Nakachi	16	12	1980	F
46224	5	Tomoe	Sakai	27	5	1978	F
74200	8	Ayumi	Hara	21	2	1979	F
51492	12	Hiromi	Isozaki	22	12	1975	F
24967	13	Miyuki	Yanagita	11	4	1981	F
32368	14	Tomomi	Miyamoto	31	12	1978	F
4884	15	Mito	Isaka	25	1	1976	F
69292	16	Yayoi	Kobayashi	18	9	1981	F
48735	17	Mayumi	Omatsu	12	7	1970	F
17805	18	Nozomi	Yamago	16	1	1975	F
33014	19	Kozue	Ando	9	7	1982	F
39010	20	Naoko	Nishigai	22	1	1969	F
50573	1	Linnea	Quiñones	17	7	1980	F
99657	2	Susana	Mora	26	1	1979	F
48441	3	Martha	Moore	14	4	1981	F
2698	4	Gina	Oceguera	9	4	1977	F
52285	5	Patricia	Pérez	17	12	1978	F
23661	6	Fátima	Leyva	14	2	1980	F
69880	7	Mónica	Vergara	2	5	1983	F
2679	8	Andrea	Rodebaugh	8	10	1966	F
77515	9	Lisa	Náñez	10	3	1977	F
92275	10	Maribel	Domínguez	18	11	1978	F
42124	11	Mónica	Gerardo	10	11	1976	F
11308	12	Yvette	Valdez	16	10	1973	F
1717	13	Mónica	González	10	10	1978	F
40960	14	Iris	Mora	22	9	1981	F
44473	15	Laurie	Hill	11	2	1970	F
37772	16	Nancy	Pinzón	6	6	1974	F
15055	17	Kendyl	Michner	3	5	1978	F
9352	18	Tánima	Rubalcaba	24	12	1980	F
60080	19	Bárbara	Almaraz	4	5	1979	F
7466	20	Denise	Ireta	4	1	1980	F
27461	3	Martha	Tarhemba	1	4	1978	F
38386	4	Adanna	Nwaneri	31	8	1975	F
22479	5	Eberechi	Opara	6	3	1976	F
34716	6	Florence	Ajayi	28	4	1977	F
19498	7	Stella	Mbachu	16	4	1978	F
81834	9	Gloria	Usieta	19	6	1977	F
26109	12	Judith	Chime	20	5	1978	F
75280	16	Florence	Iweta	29	3	1983	F
5883	17	Nkechi	Egbe	5	2	1978	F
38422	20	Ifeanyi	Chiejine	17	5	1983	F
84527	1	Jong-hui	Ri	20	8	1975	F
78097	2	In-sil	Yun	10	1	1976	F
7307	3	Song-ok	Jo	18	3	1974	F
16179	4	Sun-hui	Kim	4	4	1972	F
7247	5	Sun-hye	Kim	1	1	1977	F
89690	6	Yong-suk	Sol	4	2	1975	F
16375	7	Hyang-ok	Ri	18	12	1977	F
44185	8	Song-ryo	Kim	5	6	1976	F
48268	9	Kyong-ae	Ri	4	12	1972	F
16569	10	Kum-sil	Kim	24	12	1970	F
16650	11	Jong-ran	Jo	18	9	1971	F
31902	12	Hye-ran	Kim	19	5	1970	F
67441	13	Ae-gyong	Ri	12	9	1971	F
14030	14	Jong-ae	Pak	3	4	1974	F
46500	15	Pyol-hui	Jin	19	8	1980	F
59010	16	Kum-suk	Ri	16	8	1978	F
84344	17	Kyong-hui	Yang	21	1	1978	F
18796	18	Yong-sun	Kye	27	3	1972	F
23894	19	Ok-gyong	Jang	29	1	1980	F
38181	20	Un-ok	Kim	18	4	1978	F
4956	2	Brit	Sandaune	5	6	1972	F
1272	3	Gøril	Kringen	28	1	1972	F
31385	4	Silje	Jørgensen	5	5	1977	F
83715	5	Henriette	Viker	5	8	1973	F
78069	8	Monica	Knudsen	25	3	1975	F
49113	12	Astrid	Johannessen	10	1	1978	F
74483	13	Ragnhild	Gulbrandsen	22	2	1977	F
49154	15	Dagny	Mellgren	19	6	1978	F
70069	16	Solveig	Gulbrandsen	12	1	1981	F
556	17	Anita	Rapp	24	7	1977	F
6090	18	Anne	Tønnessen	18	3	1974	F
65709	19	Linda	Ørmen	22	3	1977	F
72974	20	Unni	Lehn	7	6	1977	F
46594	1	Svetlana	Petko	6	6	1970	F
81945	2	Yulia	Yushekivitch	14	9	1980	F
75205	3	Marina	Burakova	8	5	1966	F
31383	4	Natalia	Karasseva	30	4	1977	F
65831	5	Tatiana	Cheverda	29	8	1974	F
37971	6	Galina	Komarova	12	8	1977	F
55158	7	Tatiana	Egorova	10	3	1970	F
62577	8	Irina	Grigorieva	21	2	1972	F
23016	9	Alexandra	Svetlitskaya	20	8	1971	F
90659	10	Natalia	Barbashina	26	8	1973	F
42830	11	Olga	Letyushova	29	12	1975	F
26579	12	Alla	Volkova	12	4	1968	F
90185	13	Elena	Fomina	5	4	1979	F
20242	14	Olga	Karasseva	6	10	1975	F
42638	15	Larisa	Savina	25	11	1970	F
69415	16	Natalia	Filippova	7	2	1975	F
14186	17	Elena	Lissacheva	25	11	1973	F
18197	18	Tatyana	Skotnikova	27	11	1978	F
95777	19	Tatiana	Zaitseva	27	8	1978	F
51247	20	Larissa	Kapitonova	4	5	1970	F
91428	1	Ulrika	Karlsson	14	10	1970	F
33354	2	Karolina	Westberg	16	5	1978	F
84530	3	Jane	Törnqvist	9	5	1975	F
52220	6	Malin	Moström	1	8	1975	F
47163	7	Cecilia	Sandell	10	6	1968	F
36318	8	Malin	Gustafsson	24	1	1980	F
31388	10	Hanna	Ljungberg	8	1	1979	F
36470	11	Victoria	Svensson	18	5	1977	F
3139	12	Ulla-Karin	Thelin	19	2	1977	F
62434	13	Hanna	Marklund	26	11	1977	F
60653	14	Jessika	Sundh	9	7	1974	F
53787	15	Linda	Gren	12	11	1974	F
98034	16	Salina	Olsson	29	8	1978	F
23207	17	Linda	Fagerström	17	3	1977	F
31442	18	Therese	Lundin	3	3	1979	F
20773	19	Minna	Heponiemi	10	8	1977	F
30916	20	Tina	Nordlund	19	3	1977	F
53620	2	Lorrie	Fair	5	8	1978	F
471	3	Christie	Rampone	24	6	1975	F
71411	7	Sara	Whalen	28	4	1976	F
14832	8	Shannon	MacMillan	7	10	1974	F
18634	12	Cindy	Parlow	8	5	1978	F
24048	17	Danielle	Fotopoulos	24	3	1976	F
34806	19	Tracy	Ducar	18	6	1973	F
58480	20	Kate	Markgraf	23	8	1976	F
60914	3	Juan Pablo	Sorín	5	5	1976	M
31684	4	Mauricio	Pochettino	2	3	1972	M
76131	6	Walter	Samuel	23	3	1978	M
2174	13	Diego	Placente	24	4	1977	M
26200	15	Claudio	Husaín	20	11	1974	M
25906	16	Pablo	Aimar	3	11	1979	M
45985	17	Gustavo	López	13	4	1973	M
11130	18	Kily	González	4	8	1974	M
12056	23	Roberto	Bonano	24	1	1970	M
48592	1	Geert	De Vlieger	16	10	1971	M
80262	6	Timmy	Simons	11	12	1976	M
34376	8	Bart	Goor	9	4	1973	M
64922	9	Wesley	Sonck	9	8	1978	M
3447	10	Johan	Walem	1	2	1972	M
2977	12	Peter	Van der Heyden	16	7	1976	M
12777	13	Franky	Vandendriessche	7	4	1971	M
91831	14	Sven	Vermant	4	4	1973	M
12842	15	Jacky	Peeters	13	12	1969	M
21070	16	Daniel	Van Buyten	7	2	1978	M
42565	17	Gaëtan	Englebert	11	6	1976	M
46499	18	Yves	Vanderhaeghe	30	1	1970	M
88716	19	Bernd	Thijs	28	6	1978	M
3038	20	Branko	Strupar	9	2	1970	M
44716	23	Frédéric	Herpoel	16	8	1974	M
64377	1	not applicable	Marcos	4	8	1973	M
42918	3	not applicable	Lúcio	8	5	1978	M
66308	4	Roque	Júnior	31	8	1976	M
9270	5	not applicable	Edmílson	10	7	1976	M
57975	7	not applicable	Ricardinho	23	5	1976	M
45956	8	Gilberto	Silva	7	10	1976	M
57361	11	not applicable	Ronaldinho	21	3	1980	M
93236	13	Juliano	Belletti	20	6	1976	M
9454	14	Ânderson	Polga	9	2	1979	M
79283	15	not applicable	Kléberson	19	6	1979	M
29601	16	not applicable	Júnior	20	6	1973	M
6280	18	not applicable	Vampeta	13	3	1974	M
20389	19	Juninho	Paulista	22	2	1973	M
26695	20	not applicable	Edílson	17	9	1971	M
89804	21	not applicable	Luizão	14	11	1975	M
1939	22	Rogério	Ceni	22	1	1973	M
58388	23	not applicable	Kaká	22	4	1982	M
60766	2	Bill	Tchato	14	5	1975	M
86465	8	not applicable	Geremi	20	12	1978	M
67466	11	Pius	Ndiefi	5	7	1975	M
83436	13	Lucien	Mettomo	19	4	1977	M
60079	14	Joël	Epalle	20	2	1978	M
63567	15	Nicolas	Alnoudji	9	12	1979	M
99681	18	Patrick	Suffo	17	1	1978	M
56970	19	Eric	Djemba-Djemba	4	5	1981	M
59683	22	Carlos	Kameni	18	2	1984	M
18536	23	Daniel	Kome	19	5	1980	M
31496	1	Qi	An	21	6	1981	M
77096	2	Enhua	Zhang	28	4	1973	M
83943	3	Pu	Yang	30	3	1978	M
29611	4	Chengying	Wu	21	4	1975	M
24535	5	Zhiyi	Fan	6	11	1969	M
37402	6	Jiayi	Shao	10	4	1980	M
50519	7	Jihai	Sun	30	9	1977	M
28870	8	Tie	Li	18	5	1977	M
5235	9	Mingyu	Ma	4	2	1970	M
27445	10	Haidong	Hao	9	5	1970	M
19411	11	Genwei	Yu	7	1	1974	M
5845	12	Maozhen	Su	30	7	1972	M
13701	13	Yao	Gao	13	7	1977	M
12619	14	Weifeng	Li	1	12	1978	M
90061	15	Junzhe	Zhao	18	4	1979	M
57338	16	Bo	Qu	15	7	1981	M
60686	17	Wei	Du	9	2	1982	M
71211	18	Xiaopeng	Li	20	6	1975	M
68056	19	Hong	Qi	3	6	1976	M
84550	20	Chen	Yang	17	1	1974	M
39905	21	Yunlong	Xu	17	2	1979	M
2177	22	Jin	Jiang	7	10	1968	M
92129	23	Chuliang	Ou	26	8	1968	M
74709	1	Erick	Lonnis	9	9	1965	M
56632	2	Jervis	Drummond	8	9	1976	M
50749	3	Luis	Marín	10	8	1974	M
56613	4	Mauricio	Wright	20	12	1970	M
32696	5	Gilberto	Martínez	1	10	1979	M
67575	6	Wílmer	López	8	3	1971	M
3776	7	Rolando	Fonseca	6	6	1974	M
26474	8	Mauricio	Solís	13	12	1972	M
22046	9	Paulo	Wanchope	31	7	1976	M
68890	10	Walter	Centeno	6	10	1974	M
55170	11	Rónald	Gómez	24	1	1975	M
20880	12	Winston	Parks	12	10	1981	M
75965	13	Daniel	Vallejos	27	5	1981	M
56119	14	Juan José	Rodríguez	23	6	1967	M
85975	15	Harold	Wallace	7	9	1975	M
14189	16	Steven	Bryce	16	8	1977	M
86109	18	Álvaro	Mesén	24	12	1972	M
98663	19	Rodrigo	Cordero	4	12	1973	M
96930	20	William	Sunsing	12	5	1977	M
29122	21	Pablo	Chinchilla	21	12	1978	M
73169	22	Carlos	Castro	10	9	1978	M
74506	23	Lester	Morgan	2	5	1976	M
85818	1	Stipe	Pletikosa	8	1	1979	M
29621	3	Josip	Šimunić	18	2	1978	M
87187	4	Stjepan	Tomas	6	3	1976	M
55293	5	Milan	Rapaić	16	8	1973	M
70100	6	Boris	Živković	15	11	1975	M
10638	7	Davor	Vugrinec	24	3	1975	M
84378	10	Niko	Kovač	15	10	1971	M
99830	12	Tomislav	Butina	30	3	1974	M
36689	15	Daniel	Šarić	4	8	1972	M
91190	16	Jurica	Vranješ	31	1	1980	M
13265	18	Ivica	Olić	14	9	1979	M
61666	21	Robert	Kovač	6	4	1974	M
53874	22	Boško	Balaban	15	10	1978	M
212	1	Thomas	Sørensen	12	6	1976	M
27808	4	Martin	Laursen	26	7	1977	M
24031	7	Thomas	Gravesen	11	3	1976	M
63778	8	Jesper	Grønkjær	12	8	1977	M
50534	9	Jon Dahl	Tomasson	29	8	1976	M
34389	12	Niclas	Jensen	17	8	1974	M
94452	13	Steven	Lustü	13	4	1971	M
26759	14	Claus	Jensen	29	4	1977	M
89928	15	Jan	Michaelsen	28	11	1970	M
46718	17	Christian	Poulsen	28	2	1980	M
41271	18	Peter	Løvenkrands	29	1	1980	M
80170	19	Dennis	Rommedahl	22	7	1978	M
5337	20	Kasper	Bøgelund	8	10	1980	M
6985	21	Peter	Madsen	26	4	1978	M
21988	22	Jesper	Christiansen	24	4	1978	M
4393	23	Brian	Steen Nielsen	28	12	1968	M
11930	1	José Francisco	Cevallos	17	4	1971	M
59372	2	Augusto	Porozo	13	4	1974	M
98031	3	Iván	Hurtado	16	8	1974	M
92146	4	Ulises	de la Cruz	8	2	1974	M
37753	5	Alfonso	Obregón	12	5	1972	M
32567	6	Raúl	Guerrón	12	10	1976	M
74323	7	Nicolás	Asencio	26	4	1975	M
28455	8	Luis	Gómez	20	4	1972	M
3128	9	Iván	Kaviedes	24	10	1977	M
23101	10	Álex	Aguinaga	9	7	1968	M
19156	11	Agustín	Delgado	23	12	1974	M
47469	12	Oswaldo	Ibarra	8	9	1969	M
85736	13	Ángel	Fernández	2	8	1971	M
85473	14	Juan Carlos	Burbano	15	2	1969	M
90857	15	Marlon	Ayoví	27	9	1971	M
99914	16	Cléber	Chalá	29	6	1971	M
6468	17	Giovanny	Espinoza	12	4	1977	M
86943	18	Carlos	Tenorio	14	5	1979	M
42534	19	Édison	Méndez	16	3	1979	M
30306	20	Edwin	Tenorio	16	6	1976	M
87016	21	Wellington	Sánchez	19	6	1974	M
53809	22	Daniel	Viteri	12	12	1981	M
39602	23	Walter	Ayoví	11	8	1979	M
68164	2	Danny	Mills	18	5	1977	M
16557	3	Ashley	Cole	20	12	1980	M
53590	4	Trevor	Sinclair	2	3	1973	M
10663	9	Robbie	Fowler	9	4	1975	M
8307	11	Emile	Heskey	11	1	1978	M
55244	12	Wes	Brown	13	10	1979	M
91486	14	Wayne	Bridge	5	8	1980	M
61216	18	Owen	Hargreaves	20	1	1981	M
37933	19	Joe	Cole	8	11	1981	M
447	20	Darius	Vassell	13	6	1980	M
3723	21	Nicky	Butt	21	1	1975	M
59324	22	David	James	1	8	1970	M
34406	23	Kieron	Dyer	29	12	1978	M
59735	1	Ulrich	Ramé	19	9	1972	M
62062	5	Philippe	Christanval	31	8	1978	M
93048	7	Claude	Makélélé	18	2	1973	M
53533	9	Djibril	Cissé	12	8	1981	M
916	11	Sylvain	Wiltord	10	5	1974	M
66615	13	Mikaël	Silvestre	9	8	1977	M
23315	19	Willy	Sagnol	18	3	1977	M
57906	22	Johan	Micoud	24	7	1973	M
57021	23	Grégory	Coupet	31	12	1972	M
17520	2	Thomas	Linke	26	12	1969	M
71726	3	Marko	Rehmer	29	4	1972	M
73157	4	Frank	Baumann	29	10	1975	M
57588	5	Carsten	Ramelow	20	3	1974	M
55504	7	Oliver	Neuville	1	5	1973	M
45490	9	Carsten	Jancker	28	8	1974	M
97252	10	Lars	Ricken	10	7	1976	M
27787	11	Miroslav	Klose	9	6	1978	M
84003	13	Michael	Ballack	26	9	1976	M
25543	14	Gerald	Asamoah	3	10	1978	M
51287	15	Sebastian	Kehl	13	2	1980	M
3026	17	Marco	Bode	23	7	1969	M
42820	18	Jörg	Böhme	22	1	1974	M
32136	19	Bernd	Schneider	17	11	1973	M
4065	21	Christoph	Metzelder	5	11	1980	M
35264	22	Torsten	Frings	22	11	1976	M
5630	23	Hans-Jörg	Butt	28	5	1974	M
45258	2	Christian	Panucci	12	4	1973	M
15450	4	Francesco	Coco	8	1	1977	M
57378	6	Cristiano	Zanetti	14	4	1977	M
18164	8	Gennaro	Gattuso	9	1	1978	M
42038	10	Francesco	Totti	27	9	1976	M
68818	11	Cristiano	Doni	1	4	1973	M
81393	12	Christian	Abbiati	8	7	1977	M
84093	15	Mark	Iuliano	12	8	1973	M
26847	17	Damiano	Tommasi	17	5	1974	M
17035	18	Marco	Delvecchio	7	4	1973	M
42227	19	Gianluca	Zambrotta	19	2	1977	M
1311	20	Vincenzo	Montella	18	6	1974	M
37126	23	Marco	Materazzi	19	8	1973	M
21222	3	Naoki	Matsuda	14	3	1977	M
49610	4	Ryuzo	Morioka	7	10	1975	M
46807	5	Junichi	Inamoto	18	9	1979	M
99721	9	Akinori	Nishizawa	18	6	1976	M
96566	11	Takayuki	Suzuki	5	6	1976	M
35882	13	Atsushi	Yanagisawa	27	5	1977	M
42311	14	Alessandro	Santos	20	7	1977	M
89292	15	Takashi	Fukunishi	1	9	1976	M
95259	16	Kōji	Nakata	9	7	1979	M
11915	17	Tsuneyasu	Miyamoto	7	2	1977	M
12376	19	Mitsuo	Ogasawara	5	4	1979	M
58878	20	Tomokazu	Myojin	24	1	1978	M
79993	21	Kazuyuki	Toda	30	12	1977	M
48525	22	Daisuke	Ichikawa	14	5	1980	M
94511	23	Hitoshi	Sogahata	2	8	1979	M
50893	2	Francisco	Gabriel de Anda	5	6	1971	M
87592	3	Rafael	García	14	8	1974	M
44763	4	Rafael	Márquez	13	2	1979	M
13917	5	Manuel	Vidrio	23	8	1972	M
89297	6	Gerardo	Torrado	30	4	1979	M
98036	7	Ramón	Morales	10	10	1975	M
81643	9	Jared	Borgetti	14	8	1973	M
87229	13	Sigifredo	Mercado	21	12	1968	M
57272	18	Johan	Rodríguez	15	8	1975	M
76755	19	Gabriel	Caballero	5	2	1971	M
36826	20	Melvin	Brown	28	1	1979	M
56348	22	Alberto	Rodríguez	1	4	1974	M
22507	1	Ike	Shorunmu	16	10	1967	M
64104	2	Joseph	Yobo	6	9	1980	M
19121	5	Isaac	Okoronkwo	1	5	1978	M
27347	7	Pius	Ikedia	11	7	1980	M
48550	9	Bartholomew	Ogbeche	1	10	1984	M
47983	12	Austin	Ejide	8	4	1984	M
55727	13	Rabiu	Afolabi	18	4	1980	M
3741	14	Ifeanyi	Udeze	21	7	1980	M
3331	15	Justice	Christopher	24	12	1981	M
6935	16	Efe	Sodje	5	10	1972	M
74228	17	Julius	Aghahowa	12	2	1982	M
48288	18	Benedict	Akwuegbu	3	11	1974	M
22123	19	Eric	Ejiofor	21	7	1979	M
52108	20	James	Obiorah	24	8	1978	M
64893	21	John	Utaka	8	1	1982	M
39249	22	Vincent	Enyeama	29	8	1982	M
52099	23	Femi	Opabunmi	3	3	1985	M
66123	6	Estanislao	Struway	25	6	1968	M
55673	7	Richart	Báez	31	7	1973	M
87796	8	Guido	Alvarenga	24	8	1970	M
34530	9	Roque	Santa Cruz	16	8	1981	M
94060	12	Justo	Villar	30	6	1977	M
75108	14	Diego	Gavilán	1	3	1980	M
22302	15	Carlos	Bonet	2	10	1977	M
3401	16	Gustavo	Morínigo	23	1	1977	M
22263	17	Juan Carlos	Franco	17	4	1973	M
50109	18	Julio César	Cáceres	5	10	1979	M
96044	19	Daniel	Sanabria	8	2	1977	M
93337	22	Ricardo	Tavarelli	2	8	1970	M
88899	23	Nelson	Cuevas	10	1	1980	M
59886	1	Jerzy	Dudek	23	3	1973	M
99558	2	Tomasz	Kłos	7	3	1973	M
66681	3	Jacek	Zieliński	10	10	1967	M
15578	4	Michał	Żewłakow	22	4	1976	M
20085	5	Tomasz	Rząsa	11	3	1973	M
53829	6	Tomasz	Hajto	16	10	1972	M
34709	7	Piotr	Świerczewski	8	4	1972	M
93812	8	Cezary	Kucharski	17	2	1972	M
69995	9	Paweł	Kryszałowicz	23	6	1974	M
29986	10	Radosław	Kałużny	2	2	1974	M
75230	11	Emmanuel	Olisadebe	22	12	1978	M
13151	12	Radosław	Majdan	10	5	1972	M
37701	13	Arkadiusz	Głowacki	13	3	1979	M
3927	14	Marcin	Żewłakow	22	4	1976	M
68907	15	Tomasz	Wałdoch	10	5	1971	M
68833	16	Maciej	Murawski	20	2	1974	M
90321	17	Arkadiusz	Bąk	6	10	1974	M
49007	18	Jacek	Krzynówek	15	5	1976	M
7088	19	Maciej	Żurawski	12	9	1976	M
46873	20	Jacek	Bąk	24	3	1973	M
6017	21	Marek	Koźmiński	7	2	1971	M
1018	22	Adam	Matysek	19	7	1968	M
9579	23	Paweł	Sibik	15	2	1971	M
16675	1	Vítor	Baía	15	10	1969	M
73722	2	Jorge	Costa	14	10	1971	M
39199	3	Abel	Xavier	30	11	1972	M
48643	4	Marco	Caneira	9	2	1979	M
23927	5	Fernando	Couto	2	8	1969	M
70308	6	Paulo	Sousa	30	8	1970	M
57496	7	Luís	Figo	4	11	1972	M
70698	8	João	Pinto	19	8	1971	M
57982	9	not applicable	Pauleta	28	4	1973	M
62808	10	Rui	Costa	29	3	1972	M
88800	11	Sérgio	Conceição	15	11	1974	M
83823	12	Hugo	Viana	15	1	1983	M
82191	13	Jorge	Andrade	9	4	1978	M
6162	14	Pedro	Barbosa	6	8	1970	M
67041	15	Nélson	Pereira	20	10	1975	M
45712	16	not applicable	Ricardo	11	2	1976	M
91925	17	Paulo	Bento	20	6	1969	M
11424	18	Nuno	Frechaut	24	9	1977	M
7559	19	not applicable	Capucho	21	2	1972	M
92307	20	not applicable	Petit	25	9	1976	M
57631	21	Nuno	Gomes	5	7	1976	M
37140	22	not applicable	Beto	3	5	1976	M
61068	23	Rui	Jorge	27	3	1973	M
32512	1	Shay	Given	20	4	1976	M
56778	2	Steve	Finnan	24	4	1976	M
59412	3	Ian	Harte	31	8	1977	M
57630	4	Kenny	Cunningham	28	6	1971	M
105	8	Matt	Holland	11	4	1974	M
18106	9	Damien	Duff	2	3	1979	M
84878	10	Robbie	Keane	8	7	1980	M
32499	11	Kevin	Kilbane	1	2	1977	M
34285	12	Mark	Kinsella	12	8	1972	M
20792	13	David	Connolly	6	6	1977	M
22209	14	Gary	Breen	12	12	1973	M
98853	15	Richard	Dunne	21	9	1979	M
79072	16	Dean	Kiely	10	10	1970	M
83418	19	Clinton	Morrison	14	5	1979	M
74235	20	Andrew	O'Brien	29	6	1979	M
19727	21	Steven	Reid	10	3	1981	M
57284	22	Lee	Carsley	28	2	1974	M
86448	1	Ruslan	Nigmatullin	7	10	1974	M
70372	2	Yuri	Kovtun	5	1	1970	M
79578	4	Alexey	Smertin	1	5	1975	M
27678	5	Andrei	Solomatin	9	9	1975	M
65105	6	Igor	Semshov	6	4	1978	M
66907	9	Yegor	Titov	29	5	1976	M
32046	13	Vyacheslav	Dayev	6	9	1972	M
64408	14	Igor	Chugainov	6	4	1970	M
51792	15	Dmitri	Alenichev	20	10	1972	M
89971	16	Aleksandr	Kerzhakov	27	11	1982	M
75536	17	Sergei	Semak	27	2	1976	M
53680	18	Dmitri	Sennikov	24	6	1976	M
76375	19	Ruslan	Pimenov	25	11	1981	M
14715	20	Marat	Izmailov	21	9	1982	M
28437	21	Dmitri	Khokhlov	22	12	1975	M
4731	22	Dmitri	Sychev	26	10	1983	M
76203	23	Aleksandr	Filimonov	15	10	1973	M
90725	3	Redha	Tukar	29	11	1975	M
16522	5	Mohsin	Al-Harthi	17	7	1976	M
48349	6	Fouzi	Al-Shehri	15	5	1980	M
90435	8	Mohammed	Noor	26	2	1978	M
11262	10	Mohammad	Al-Shalhoub	8	12	1980	M
77199	13	Hussein	Abdulghani	21	1	1977	M
76946	14	Abdulaziz	Al-Khathran	31	7	1973	M
26868	15	Abdullah	Al-Jumaan	10	11	1977	M
75813	17	Abdullah	Al-Waked	29	9	1975	M
585	19	Omar	Al-Ghamdi	11	4	1979	M
683	20	Al Hasan	Al-Yami	21	8	1972	M
99270	21	Mabrouk	Zaid	11	2	1979	M
29107	22	Mohammed	Al-Khojali	15	1	1973	M
12568	23	Mansour	Al-Thagafi	14	1	1979	M
16571	1	Tony	Sylva	17	5	1975	M
27229	2	Omar	Daf	12	2	1977	M
81968	3	Pape	Sarr	7	12	1977	M
50303	4	Pape	Malick Diop	29	12	1974	M
82601	5	Alassane	N'Dour	12	12	1981	M
95302	6	Aliou	Cissé	24	3	1976	M
1462	7	Henri	Camara	10	5	1977	M
75923	8	Amara	Traoré	25	9	1965	M
5029	9	Souleymane	Camara	22	12	1982	M
62977	10	Khalilou	Fadiga	30	12	1974	M
84943	11	El Hadji	Diouf	15	1	1981	M
42976	12	Amdy	Faye	12	3	1977	M
16046	13	Lamine	Diatta	2	7	1975	M
62939	14	Moussa	N'Diaye	20	2	1979	M
35019	15	Salif	Diao	10	2	1977	M
2673	16	Omar	Diallo	28	9	1972	M
37924	17	Ferdinand	Coly	10	9	1973	M
91308	18	Pape	Thiaw	5	2	1981	M
82212	19	Papa Bouba	Diop	28	1	1978	M
35460	20	Sylvain	N'Diaye	25	6	1976	M
35489	21	Habib	Beye	19	10	1977	M
58665	22	Kalidou	Cissokho	28	8	1978	M
64668	23	Makhtar	N'Diaye	31	12	1981	M
49309	1	Marko	Simeunovič	6	12	1967	M
22318	2	Goran	Sankovič	18	6	1979	M
84477	3	Željko	Milinovič	12	10	1969	M
13966	4	Muamer	Vugdalić	25	8	1977	M
48946	5	Marinko	Galič	22	4	1970	M
4672	6	Aleksander	Knavs	5	12	1975	M
75494	7	Džoni	Novak	4	9	1969	M
22187	8	Aleš	Čeh	7	4	1968	M
48910	9	Milan	Osterc	4	7	1975	M
64619	10	Zlatko	Zahovič	1	2	1971	M
6135	11	Miran	Pavlin	8	10	1971	M
55616	12	Mladen	Dabanovič	13	9	1971	M
30524	13	Mladen	Rudonja	26	7	1971	M
75095	14	Saša	Gajser	11	2	1974	M
26609	15	Rajko	Tavčar	21	7	1974	M
12511	16	Senad	Tiganj	28	8	1975	M
68168	17	Zoran	Pavlović	27	6	1976	M
44943	18	Milenko	Ačimovič	15	2	1977	M
31903	19	Amir	Karić	31	12	1973	M
74981	20	Nastja	Čeh	26	1	1978	M
649	21	Sebastjan	Cimirotič	14	9	1974	M
32449	22	Dejan	Nemec	1	3	1977	M
54102	23	Spasoje	Bulajič	24	11	1975	M
72876	2	Cyril	Nzama	26	6	1974	M
14062	3	Bradley	Carnell	21	1	1977	M
65611	4	Aaron	Mokoena	25	11	1980	M
10439	5	Jacob	Lekgetho	24	3	1974	M
21000	6	MacBeth	Sibaya	25	11	1977	M
30964	8	Thabo	Mngomeni	24	6	1969	M
65059	9	MacDonald	Mukansi	26	5	1975	M
53464	10	Bennett	Mnguni	18	3	1974	M
27802	11	Jabu	Pule	11	7	1980	M
99521	12	Teboho	Mokoena	10	7	1974	M
22393	14	Siyabonga	Nomvethe	2	12	1977	M
5390	15	Sibusiso	Zuma	23	6	1975	M
57595	16	Andre	Arendse	27	6	1967	M
13782	20	Calvin	Marlin	20	4	1976	M
38095	21	Steven	Pienaar	17	3	1982	M
68024	22	Thabang	Molefe	11	4	1979	M
73319	23	George	Koumantarakis	27	3	1974	M
26659	2	Young-min	Hyun	25	12	1979	M
7865	4	Jin-cheul	Choi	26	3	1971	M
51785	5	Nam-il	Kim	14	3	1977	M
37114	8	Tae-uk	Choi	13	3	1981	M
56626	9	Ki-hyeon	Seol	8	1	1979	M
46519	10	Young-pyo	Lee	23	4	1977	M
60562	13	Eul-yong	Lee	8	9	1975	M
22338	14	Chun-soo	Lee	9	7	1981	M
39884	16	Du-ri	Cha	25	7	1980	M
68095	17	Jong-hwan	Yoon	16	2	1973	M
26616	19	Jung-hwan	Ahn	27	1	1976	M
25724	21	Ji-sung	Park	25	2	1981	M
83544	22	Chong-gug	Song	20	2	1979	M
42690	23	Eun-sung	Choi	5	4	1971	M
61793	1	Iker	Casillas	20	5	1981	M
19229	2	Curro	Torres	27	12	1976	M
29082	3	not applicable	Juanfran	15	7	1976	M
20643	4	Iván	Helguera	18	3	1975	M
51089	5	Carles	Puyol	13	4	1978	M
23800	8	Rubén	Baraja	11	7	1975	M
71130	10	Diego	Tristán	5	1	1976	M
24963	11	Javier	de Pedro	4	8	1973	M
23336	12	Albert	Luque	11	3	1978	M
45039	13	not applicable	Ricardo	30	12	1971	M
21683	14	David	Albelda	1	9	1977	M
40852	15	Enrique	Romero	23	6	1971	M
37161	16	Gaizka	Mendieta	27	3	1974	M
76612	17	Juan Carlos	Valerón	17	6	1975	M
14456	18	not applicable	Sergio	10	11	1976	M
29415	19	not applicable	Xavi	25	1	1980	M
70144	22	not applicable	Joaquín	21	7	1981	M
95116	23	Pedro	Contreras	7	1	1972	M
6256	2	Olof	Mellberg	3	9	1977	M
56718	4	Johan	Mjällby	9	2	1971	M
53821	5	Michael	Svensson	25	11	1975	M
5583	6	Tobias	Linderoth	21	4	1979	M
42808	7	Niclas	Alexandersson	29	12	1971	M
85432	8	Anders	Svensson	17	7	1976	M
84022	9	Freddie	Ljungberg	16	4	1977	M
45212	10	Marcus	Allbäck	5	7	1973	M
22071	12	Magnus	Kihlstedt	29	2	1972	M
95369	13	Tomas	Antonelius	7	5	1973	M
35312	14	Erik	Edman	11	11	1978	M
68329	15	Andreas	Jakobsson	6	10	1972	M
59548	17	Magnus	Svensson	10	3	1969	M
20557	18	Mattias	Jonson	16	1	1974	M
74139	19	Pontus	Farnerud	4	6	1980	M
62207	20	Daniel	Andersson	28	8	1977	M
80105	21	Zlatan	Ibrahimović	3	10	1981	M
71531	22	Andreas	Andersson	10	4	1974	M
47401	23	Andreas	Isaksson	3	10	1981	M
44407	4	Mohamed	Mkacher	25	5	1975	M
640	5	Ziad	Jaziri	12	7	1978	M
72780	7	Imed	Mhedhebi	22	3	1976	M
15858	8	Hassen	Gabsi	23	2	1974	M
87702	12	Raouf	Bouzaiene	16	8	1970	M
55391	14	Hamdi	Marzouki	23	1	1977	M
76769	15	Radhi	Jaïdi	30	8	1975	M
58954	16	Hassen	Bejaoui	14	2	1976	M
99847	18	Selim	Benachour	8	9	1981	M
32986	19	Emir	Mkademi	20	8	1978	M
63935	20	Ali	Zitouni	11	1	1981	M
56293	22	Ahmed	El-Jaouachi	13	7	1975	M
61478	1	Rüştü	Reçber	10	5	1973	M
52032	2	Emre	Aşık	13	12	1973	M
94559	3	Bülent	Korkmaz	24	11	1968	M
79130	4	Fatih	Akyel	26	12	1977	M
44850	5	Alpay	Özalan	29	5	1973	M
37782	6	Arif	Erdem	2	1	1972	M
31907	7	Okan	Buruk	19	10	1973	M
63089	8	Tugay	Kerimoğlu	24	8	1970	M
58212	9	Hakan	Şükür	1	9	1971	M
21108	10	Yıldıray	Baştürk	24	12	1978	M
23883	11	Hasan	Şaş	1	8	1976	M
49485	12	Ömer	Çatkıç	15	10	1974	M
59617	13	Muzzy	Izzet	31	10	1974	M
16859	14	Tayfur	Havutçu	23	4	1970	M
98680	15	Nihat	Kahveci	23	11	1979	M
4455	16	Ümit	Özat	30	10	1976	M
41133	17	İlhan	Mansız	10	8	1975	M
65298	18	Ergün	Penbe	17	5	1972	M
58069	19	Abdullah	Ercan	8	12	1971	M
78533	20	Hakan	Ünsal	14	5	1973	M
46497	21	Emre	Belözoğlu	7	9	1980	M
31566	22	Ümit	Davala	30	7	1973	M
5081	23	Zafer	Özgültekin	10	3	1975	M
9888	3	Gregg	Berhalter	1	8	1973	M
58649	4	Pablo	Mastroeni	29	8	1976	M
88043	5	John	O'Brien	29	8	1977	M
97784	7	Eddie	Lewis	17	5	1974	M
38074	11	Clint	Mathis	25	11	1976	M
77238	14	Steve	Cherundolo	19	2	1979	M
78068	15	Josh	Wolff	25	2	1977	M
49219	16	Carlos	Llamosa	30	6	1969	M
91976	17	DaMarcus	Beasley	24	5	1982	M
5728	21	Landon	Donovan	4	3	1982	M
92064	22	Tony	Sanneh	1	6	1971	M
91888	1	Fabián	Carini	26	12	1979	M
17321	2	Gustavo	Méndez	3	2	1971	M
31352	3	Alejandro	Lembo	15	2	1978	M
38683	4	Paolo	Montero	3	9	1971	M
76244	5	Pablo	García	11	5	1977	M
49428	6	Darío	Rodríguez	17	9	1974	M
45056	7	Gianni	Guigou	22	2	1975	M
41694	8	Gustavo	Varela	14	5	1978	M
74863	9	Darío	Silva	2	11	1972	M
30094	10	Fabián	O'Neill	14	10	1973	M
95938	11	Federico	Magallanes	22	8	1976	M
79836	12	Gustavo	Munúa	27	1	1978	M
64372	13	Sebastián	Abreu	17	10	1976	M
3960	14	Gonzalo	Sorondo	9	10	1979	M
22489	15	Nicolás	Olivera	30	5	1978	M
3231	16	Marcelo	Romero	4	7	1976	M
46554	17	Mario	Regueiro	14	9	1978	M
48761	18	Richard	Morales	21	2	1975	M
87205	19	Joe	Bizera	17	5	1980	M
66684	20	Álvaro	Recoba	17	3	1976	M
86087	21	Diego	Forlán	19	5	1979	M
97963	22	Gonzalo	de los Santos	19	7	1976	M
54429	23	Federico	Elduayen	25	6	1977	M
71063	1	Romina	Ferro	26	6	1980	F
71461	2	Clarisa	Huber	22	12	1984	F
66491	3	Mariela	Ricotti	2	4	1979	F
92592	4	Andrea	Gonsebate	7	5	1977	F
14157	5	Marisa	Gerez	3	11	1976	F
386	6	Noelia	López	29	7	1978	F
20634	7	Karina	Alvariza	11	4	1976	F
84467	8	Natalia	Gatti	20	10	1982	F
17212	9	Yesica	Arrien	1	7	1980	F
23308	10	Rosana	Gómez	13	7	1980	F
34390	11	Marisol	Medina	11	5	1980	F
19263	12	Vanina	Correa	14	8	1983	F
27330	13	Nancy	Díaz	14	3	1973	F
91838	14	Fabiana	Vallejos	30	7	1985	F
70312	15	Yanina	Gaitán	3	6	1978	F
44227	16	Adela	Medina	3	11	1978	F
95150	17	Valeria	Cotelo	26	3	1984	F
17521	18	Mariela	Coronel	20	6	1981	F
60387	19	Celeste	Barbitta	22	5	1979	F
80199	20	Elizabeth	Villanueva	29	10	1974	F
77947	1	Cassandra	Kell	8	8	1980	F
29106	2	Gillian	Foster	28	8	1976	F
55691	6	Rhian	Davies	5	1	1981	F
1374	8	Bryony	Duus	7	10	1977	F
69209	9	April	Mann	21	4	1978	F
47947	11	Heather	Garriock	21	12	1982	F
64332	12	Melissa	Barbieri	20	1	1980	F
16853	13	Karla	Reuter	14	6	1984	F
36789	14	Pamela	Grant	15	11	1982	F
66483	15	Tal	Karp	30	12	1981	F
5773	16	Taryn	Rockall	11	11	1977	F
12322	17	Danielle	Small	7	2	1979	F
30996	18	Amy	Beattie	8	9	1980	F
64907	20	Hayley	Crawford	27	3	1984	F
64954	2	not applicable	Simone	10	2	1981	F
31275	5	Renata	Costa	8	7	1986	F
78286	6	not applicable	Michele	10	6	1984	F
54956	8	not applicable	Rafaela	23	5	1981	F
78447	9	not applicable	Kelly	8	5	1985	F
7458	10	not applicable	Marta	19	2	1986	F
93057	11	not applicable	Cristiane	15	5	1985	F
73954	12	not applicable	Giselle	20	11	1983	F
22757	13	not applicable	Mônica	4	4	1978	F
85281	14	not applicable	Rosana	7	7	1982	F
42794	15	Renata	Diniz	1	11	1985	F
46780	18	not applicable	Daniela	12	1	1984	F
84576	20	not applicable	Milene	18	6	1979	F
74702	2	Christine	Latham	15	9	1981	F
86178	3	Linda	Consolante	23	5	1982	F
15381	4	Sasha	Andrews	24	2	1983	F
85437	8	Kristina	Kiss	13	2	1981	F
35069	9	Rhian	Wilkinson	12	5	1982	F
20	11	Randee	Hermus	14	11	1979	F
97813	12	Christine	Sinclair	12	6	1983	F
28528	13	Diana	Matheson	6	4	1984	F
80374	14	Carmelina	Moscato	2	5	1984	F
20854	15	Kara	Lang	22	10	1986	F
36636	16	Brittany	Timko	5	9	1985	F
77759	18	Tanya	Dennis	26	8	1985	F
33982	19	Erin	McLeod	26	2	1983	F
76027	20	Taryn	Swiatek	4	2	1981	F
66785	2	Rui	Sun	30	3	1978	F
83032	3	Jie	Li	8	7	1979	F
66877	12	Feifei	Qu	18	5	1982	F
14537	13	Wei	Teng	21	5	1974	F
44137	14	Yan	Bi	17	2	1984	F
88622	15	Liping	Ren	21	10	1978	F
95180	16	Yali	Liu	9	2	1980	F
71089	17	Lina	Pan	18	7	1977	F
28220	18	Yan	Zhao	7	5	1972	F
73561	19	Duan	Han	15	6	1983	F
18967	1	Céline	Marty	30	3	1976	F
90240	2	Sabrina	Viguier	4	1	1981	F
24658	3	Peggy	Provost	19	9	1977	F
75036	4	Laura	Georges	20	8	1984	F
93602	5	Corinne	Diacre	4	8	1974	F
45480	6	Sandrine	Soubeyrand	16	8	1973	F
20811	7	Stéphanie	Mugneret-Béghé	22	3	1974	F
25958	8	Sonia	Bompastor	8	6	1980	F
17746	9	Marinette	Pichon	26	11	1975	F
63727	10	Élodie	Woock	13	1	1976	F
18018	11	Amélie	Coquet	31	12	1984	F
22371	12	Séverine	Lecouflé	31	3	1975	F
67223	13	Anne-Laure	Casseleux	13	1	1984	F
50881	14	Virginie	Dessalle	3	7	1981	F
62829	15	Laëtitia	Tonazzi	31	1	1981	F
44882	16	Bérangère	Sapowicz	6	2	1983	F
90667	17	Marie-Ange	Kramo	20	2	1979	F
34391	18	Hoda	Lattaf	31	8	1978	F
34640	19	Severine	Goulois	18	4	1982	F
60897	20	Emmanuelle	Sykora	21	2	1976	F
15303	3	Linda	Bresonik	7	12	1983	F
41816	4	Nia	Künzer	18	1	1980	F
80012	11	Martina	Müller	18	4	1980	F
50305	12	Sonja	Fuss	5	11	1978	F
85840	16	Viola	Odebrecht	11	2	1983	F
8780	18	Kerstin	Garefrekes	4	9	1979	F
6382	19	Stefanie	Gottschlich	5	8	1978	F
9674	20	Conny	Pohlers	16	11	1978	F
96825	2	Aminatu	Ibrahim	3	1	1979	F
3333	3	Mavis	Danso	24	3	1984	F
40027	5	Patricia	Ofori	9	6	1981	F
52992	6	Florence	Okoe	12	11	1984	F
68909	8	Myralyn	Osei Agyemang	5	11	1981	F
3320	9	Akua	Anokyewaa	15	10	1984	F
23665	11	Gloria	Foriwa	11	5	1981	F
11692	12	Fati	Mohammed	4	6	1979	F
84693	13	Yaa	Avoe	1	7	1982	F
8624	17	Belinda	Kanda	3	11	1982	F
47004	19	Basilea	Amoa-Tetteh	7	3	1984	F
24220	4	Yasuyo	Yamagishi	28	11	1979	F
5860	7	Naoko	Kawakami	16	11	1977	F
24437	9	Eriko	Arakawa	30	10	1979	F
36911	11	Mio	Otani	5	5	1979	F
78180	14	Kyoko	Yano	3	6	1984	F
94257	15	Yuka	Miyazaki	13	10	1983	F
37697	16	Emi	Yamamoto	9	3	1982	F
30837	18	Karina	Maruyama	26	3	1983	F
80867	19	Akiko	Sudo	7	4	1984	F
4310	20	Aya	Miyama	28	1	1985	F
16023	2	Efioanwan	Ekpo	25	1	1984	F
65689	3	Bunmi	Kayode	13	4	1985	F
55990	4	Perpetua	Nkwocha	3	1	1976	F
21975	5	Onome	Ebi	8	5	1983	F
23079	8	Olaitan	Yusuf	12	1	1982	F
86360	9	Faith	Michael	28	2	1987	F
93339	12	Precious	Dede	18	1	1980	F
68804	19	Esther	Okhae	12	3	1986	F
37759	20	Vera	Okolo	5	1	1985	F
97743	3	Hwa-song	Kim	19	8	1985	F
2141	5	Kum-ok	Sin	25	11	1975	F
77201	6	Mi-ae	Ra	8	12	1975	F
15227	8	Kum-chun	Pak	22	2	1978	F
65322	9	Sun-hui	Ho	5	3	1980	F
83602	11	Yong-hui	Yun	18	3	1977	F
63421	13	Jong-sun	Song	11	3	1981	F
98467	14	Kum-ran	O	18	9	1981	F
61977	15	Un-gyong	Ri	19	11	1980	F
69790	16	Kyong-sun	Pak	23	6	1985	F
49268	17	Hye-yong	Jon	16	2	1977	F
80442	18	Kyong-hwa	Chon	7	8	1983	F
25564	20	Un-ju	Ri	25	10	1983	F
25199	3	Ane	Stangeland Horpestad	2	6	1980	F
72897	5	Karin	Bredland	7	1	1978	F
29694	7	Trine	Rønning	14	6	1982	F
66369	12	Silje	Vesterbekkmo	22	6	1983	F
5014	15	Marit Fiane	Christensen	11	12	1980	F
36571	16	Gunhild	Følstad	3	11	1981	F
45895	18	Ingrid Camilla	Fosse Sæthre	19	1	1978	F
80834	19	Kristine	Edner	8	3	1976	F
60731	20	Lise	Klaveness	19	4	1981	F
24480	4	Marina	Saenko	1	5	1975	F
64409	5	Vera	Stroukova	6	8	1981	F
94171	9	Olga	Sergaeva	8	3	1977	F
43351	14	Oksana	Shmachkova	20	6	1981	F
71664	16	Marina	Kolomiets	29	9	1972	F
17206	17	Elena	Danilova	17	6	1987	F
45845	18	Anastasia	Pustovoitova	10	2	1981	F
69440	19	Elena	Denchtchik	11	11	1973	F
51516	20	Maria	Pigaleva	19	2	1981	F
60130	1	Ho-jung	Jung	11	5	1976	F
86212	2	Ju-hee	Kim	10	3	1985	F
98861	3	Kyung-suk	Hong	14	10	1984	F
23583	4	Yu-jin	Kim	17	7	1979	F
93888	5	Hae-jung	Park	10	3	1977	F
76130	6	Suk-hee	Jin	9	7	1978	F
40778	7	Eun-sun	Park	25	12	1986	F
94525	8	In-sun	Hwang	2	2	1976	F
63581	9	Ju-hee	Song	30	10	1977	F
32577	10	Jin-hee	Kim	26	3	1981	F
67755	11	Ji-eun	Lee	16	12	1979	F
16593	12	Jung-mi	Kim	16	10	1984	F
7222	13	Yoo-jin	Kim	26	9	1981	F
82107	14	Jin-sook	Han	15	12	1979	F
25247	15	Kyul-sil	Kim	13	4	1982	F
30579	16	Sun-nam	Shin	30	5	1981	F
16803	17	Hyun-ah	Sung	5	5	1982	F
76840	18	Yu-mi	Kim	15	8	1979	F
37119	19	Myung-hwa	Lee	29	7	1973	F
65913	20	Young-sil	Yoo	1	5	1975	F
82146	1	Caroline	Jönsson	22	11	1977	F
32488	7	Sara	Larsson	13	5	1979	F
86496	8	Frida	Nordin	23	5	1982	F
85779	12	Sofia	Lundgren	20	9	1982	F
91907	13	Sara	Johansson	23	1	1980	F
95194	15	Therese	Sjögran	8	4	1977	F
56708	17	Anna	Sjöström	23	4	1977	F
82102	18	Frida	Östberg	10	12	1977	F
28523	19	Sara	Call	16	7	1977	F
29677	20	Josefine	Öqvist	23	7	1983	F
80622	2	Kylie	Bivens	24	10	1978	F
27814	4	Cat	Whitehill	10	2	1982	F
92403	7	Shannon	Boxx	29	6	1977	F
96012	10	Aly	Wagner	10	8	1980	F
17219	17	Danielle	Slaton	10	6	1980	F
42208	18	Siri	Mullinix	22	5	1978	F
1853	19	Angela	Hucles	5	7	1978	F
89236	20	Abby	Wambach	2	6	1980	F
24930	1	João	Ricardo	7	1	1970	M
66972	2	Marco	Airosa	6	8	1984	M
61845	3	not applicable	Jamba	10	7	1977	M
6457	4	Lebo	Lebo	29	5	1977	M
44205	5	not applicable	Kali	11	10	1978	M
45235	6	not applicable	Miloy	27	5	1981	M
14307	7	Paulo	Figueiredo	28	11	1972	M
88171	8	André	Macanga	14	5	1978	M
86226	9	not applicable	Mantorras	18	3	1982	M
7482	10	not applicable	Akwá	30	5	1977	M
22865	11	not applicable	Mateus	19	6	1984	M
4803	12	not applicable	Lamá	1	2	1981	M
13744	13	Edson	Nobre	3	2	1980	M
74131	14	not applicable	Mendonça	9	10	1982	M
40794	15	Rui	Marques	3	9	1977	M
78483	16	not applicable	Flávio	20	12	1979	M
95366	17	not applicable	Zé Kalanga	12	10	1983	M
30892	18	not applicable	Love	14	3	1979	M
31166	19	Titi	Buengo	11	2	1980	M
3457	20	not applicable	Locó	25	12	1984	M
75104	21	not applicable	Delgado	1	11	1979	M
24893	22	Mário	Hipólito	1	6	1985	M
91786	23	Marco	Abreu	8	12	1974	M
86290	1	Roberto	Abbondanzieri	19	8	1972	M
78133	4	Fabricio	Coloccini	22	1	1982	M
66229	5	Esteban	Cambiasso	18	8	1980	M
64352	6	Gabriel	Heinze	19	4	1978	M
38901	7	Javier	Saviola	11	12	1981	M
77063	8	Javier	Mascherano	8	6	1984	M
85199	10	Juan Román	Riquelme	24	6	1978	M
29080	11	Carlos	Tevez	5	2	1984	M
27047	12	Leo	Franco	29	5	1977	M
73619	13	Lionel	Scaloni	16	5	1978	M
27419	14	Rodrigo	Palacio	5	2	1982	M
91357	15	Gabriel	Milito	7	9	1980	M
16541	17	Leandro	Cufré	9	5	1978	M
33570	18	Maxi	Rodríguez	2	1	1981	M
14758	19	Lionel	Messi	24	6	1987	M
38198	20	Julio	Cruz	10	10	1974	M
56532	21	Nicolás	Burdisso	12	4	1981	M
48161	22	Lucho	González	19	1	1981	M
66580	23	Óscar	Ustari	3	7	1986	M
78863	1	Mark	Schwarzer	6	10	1972	M
91832	2	Lucas	Neill	9	3	1978	M
66908	3	Craig	Moore	12	12	1975	M
44926	4	Tim	Cahill	6	12	1979	M
21864	5	Jason	Culina	5	8	1980	M
24935	6	Tony	Popovic	4	7	1973	M
83566	7	Brett	Emerton	22	2	1979	M
26858	8	Josip	Skoko	10	12	1975	M
78071	9	Mark	Viduka	9	10	1975	M
14290	10	Harry	Kewell	22	9	1978	M
6205	11	Stan	Lazaridis	16	8	1972	M
6384	12	Ante	Covic	13	6	1975	M
63129	13	Vince	Grella	5	10	1979	M
60008	14	Scott	Chipperfield	30	12	1975	M
59039	15	John	Aloisi	5	2	1976	M
69089	16	Michael	Beauchamp	8	3	1981	M
92892	17	Archie	Thompson	23	10	1978	M
55125	18	Zeljko	Kalac	16	12	1972	M
6754	19	Joshua	Kennedy	20	8	1982	M
14862	20	Luke	Wilkshire	2	10	1981	M
90087	21	Mile	Sterjovski	27	5	1979	M
36196	22	Mark	Milligan	4	8	1985	M
84486	23	Mark	Bresciano	11	2	1980	M
98607	4	not applicable	Juan	1	2	1979	M
20372	7	not applicable	Adriano	17	2	1982	M
47627	13	not applicable	Cicinho	24	6	1980	M
32968	14	not applicable	Luisão	13	2	1981	M
74340	15	not applicable	Cris	3	6	1977	M
30363	16	not applicable	Gilberto	25	4	1976	M
87223	18	not applicable	Mineiro	2	8	1975	M
37735	19	Juninho	Pernambucano	30	1	1975	M
54042	21	not applicable	Fred	3	10	1983	M
11275	22	Júlio	César	3	9	1979	M
13354	23	not applicable	Robinho	25	1	1984	M
52458	4	Michael	Umaña	16	7	1982	M
30163	6	Danny	Fonseca	7	11	1979	M
57722	7	Christian	Bolaños	17	5	1984	M
12856	12	Leonardo	González	21	11	1980	M
1674	13	Kurt	Bernard	8	8	1977	M
7614	14	Randall	Azofeifa	30	12	1984	M
13659	16	Carlos	Hernández	9	4	1982	M
97927	17	Gabriel	Badilla	30	6	1984	M
66817	18	José Francisco	Porras	8	11	1970	M
55781	19	Álvaro	Saborío	25	3	1982	M
37092	20	Douglas	Sequeira	23	8	1977	M
17028	21	Víctor	Núñez	15	4	1980	M
71248	22	Michael	Rodríguez	30	12	1981	M
82853	23	Wardy	Alfaro	31	12	1977	M
97008	2	Darijo	Srna	1	5	1982	M
13539	8	Marko	Babić	28	1	1981	M
12373	9	Dado	Pršo	5	11	1974	M
36053	11	Mario	Tokić	23	6	1975	M
59970	12	Joey	Didulica	14	10	1977	M
29491	14	Luka	Modrić	9	9	1985	M
31316	15	Ivan	Leko	7	2	1978	M
92627	16	Jerko	Leko	9	4	1980	M
38099	17	Ivan	Klasnić	29	1	1980	M
76289	19	Niko	Kranjčar	13	8	1984	M
15428	22	Ivan	Bošnjak	6	2	1979	M
53062	1	Petr	Čech	20	5	1982	M
86056	2	Zdeněk	Grygera	14	5	1980	M
26250	3	Pavel	Mareš	18	1	1976	M
69743	4	Tomáš	Galásek	15	1	1973	M
23972	5	Radoslav	Kováč	11	11	1979	M
35103	6	Marek	Jankulovski	9	5	1977	M
40666	7	Libor	Sionko	1	2	1977	M
56023	8	Karel	Poborský	30	3	1972	M
81477	9	Jan	Koller	30	3	1973	M
29090	10	Tomáš	Rosický	4	10	1980	M
64760	11	Pavel	Nedvěd	30	8	1972	M
36056	12	Vratislav	Lokvenc	27	9	1973	M
46512	13	Martin	Jiránek	25	5	1979	M
4349	14	David	Jarolím	17	5	1979	M
14907	15	Milan	Baroš	28	10	1981	M
44775	16	Jaromír	Blažek	29	12	1972	M
65749	17	Jiří	Štajner	27	5	1976	M
21701	18	Marek	Heinz	4	8	1977	M
30878	19	Jan	Polák	14	3	1981	M
65590	20	Jaroslav	Plašil	5	1	1982	M
91280	21	Tomáš	Ujfaluši	24	3	1978	M
54533	22	David	Rozehnal	5	7	1980	M
7338	23	Antonín	Kinský	31	5	1975	M
29399	1	Edwin	Villafuerte	12	3	1979	M
72804	2	Jorge	Guagua	28	9	1981	M
36290	5	José Luis	Perlaza	6	10	1981	M
54675	6	Patricio	Urrutia	15	10	1978	M
17733	7	Christian	Lara	27	4	1980	M
51733	9	Félix	Borja	2	4	1983	M
18894	12	Cristian	Mora	26	8	1979	M
75905	13	Paúl	Ambrosi	14	10	1980	M
96174	14	Segundo	Castillo	15	5	1982	M
49265	16	Antonio	Valencia	4	8	1985	M
61229	18	Néicer	Reasco	23	7	1977	M
5227	19	Luis	Saritama	20	10	1983	M
27162	22	Damián	Lanza	10	4	1982	M
63618	23	Christian	Benítez	1	5	1986	M
72859	1	Paul	Robinson	15	10	1979	M
62157	4	Steven	Gerrard	30	5	1980	M
71420	6	John	Terry	7	12	1980	M
65534	8	Frank	Lampard	20	6	1978	M
99967	9	Wayne	Rooney	24	10	1985	M
50944	15	Jamie	Carragher	28	1	1978	M
17428	17	Jermaine	Jenas	18	2	1983	M
50718	18	Michael	Carrick	28	7	1981	M
64864	19	Aaron	Lennon	16	4	1987	M
86227	20	Stewart	Downing	22	7	1984	M
77532	21	Peter	Crouch	30	1	1981	M
57447	22	Scott	Carson	3	9	1985	M
24015	23	Theo	Walcott	16	3	1989	M
30652	1	Mickaël	Landreau	14	5	1979	M
63176	2	Jean-Alain	Boumsong	14	12	1979	M
4469	3	Eric	Abidal	11	9	1979	M
68803	5	William	Gallas	17	8	1977	M
18830	7	Florent	Malouda	13	6	1980	M
51388	8	Vikash	Dhorasoo	10	10	1973	M
31668	9	Sidney	Govou	27	7	1979	M
48944	14	Louis	Saha	8	8	1978	M
98022	17	Gaël	Givet	9	10	1981	M
58415	18	Alou	Diarra	15	7	1981	M
43681	21	Pascal	Chimbonda	21	2	1979	M
55659	22	Franck	Ribéry	7	4	1983	M
50326	2	Marcell	Jansen	4	11	1985	M
43481	3	Arne	Friedrich	29	5	1979	M
27557	4	Robert	Huth	18	8	1984	M
94304	6	Jens	Nowotny	11	1	1974	M
43400	7	Bastian	Schweinsteiger	1	8	1984	M
27261	9	Mike	Hanke	5	11	1983	M
73973	15	Thomas	Hitzlsperger	5	4	1982	M
18599	16	Philipp	Lahm	11	11	1983	M
2328	17	Per	Mertesacker	29	9	1984	M
8154	18	Tim	Borowski	2	5	1980	M
36287	20	Lukas	Podolski	4	6	1985	M
24324	22	David	Odonkor	21	2	1984	M
30693	23	Timo	Hildebrand	5	4	1979	M
17027	1	Sammy	Adjei	1	9	1980	M
24586	2	Hans	Sarpei	28	6	1976	M
38556	3	Asamoah	Gyan	22	11	1985	M
84395	4	Samuel	Kuffour	3	9	1976	M
29967	5	John	Mensah	29	11	1982	M
3949	6	Emmanuel	Pappoe	3	3	1981	M
52437	7	Illiasu	Shilla	26	10	1982	M
12805	8	Michael	Essien	3	12	1982	M
49882	9	Derek	Boateng	2	5	1983	M
9728	10	Stephen	Appiah	24	12	1980	M
50641	11	Sulley	Muntari	27	8	1984	M
98986	12	Alex	Tachie-Mensah	15	2	1977	M
384	13	Habib	Mohamed	10	12	1983	M
79316	14	Matthew	Amoah	24	10	1980	M
25083	15	John	Paintsil	15	6	1981	M
97589	16	George	Owu	17	6	1982	M
23035	17	Daniel	Quaye	25	12	1980	M
77757	18	Eric	Addo	12	11	1978	M
70474	19	Razak	Pimpong	30	12	1982	M
23846	20	Otto	Addo	9	6	1975	M
27915	21	Issah	Ahmed	24	5	1982	M
81778	22	Richard	Kingson	13	6	1978	M
51458	23	Haminu	Draman	1	4	1986	M
18605	1	Ebrahim	Mirzapour	16	9	1978	M
2909	3	Sohrab	Bakhtiarizadeh	11	9	1973	M
20762	4	Yahya	Golmohammadi	19	3	1971	M
96490	5	Rahman	Rezaei	20	2	1975	M
59901	6	Javad	Nekounam	7	9	1980	M
34386	7	Ferydoon	Zandi	26	4	1979	M
16416	8	Ali	Karimi	8	11	1978	M
47539	9	Vahid	Hashemian	21	7	1976	M
56998	11	Rasoul	Khatibi	22	9	1978	M
74059	12	Hassan	Roudbarian	6	7	1978	M
55405	13	Hossein	Kaebi	23	9	1985	M
20969	14	Andranik	Teymourian	6	3	1983	M
13809	15	Arash	Borhani	14	9	1983	M
64146	16	Reza	Enayati	23	9	1976	M
60564	17	Javad	Kazemian	23	4	1981	M
43423	18	Moharram	Navidkia	1	11	1982	M
94570	19	Amir Hossein	Sadeghi	6	9	1981	M
56844	20	Mohammad	Nosrati	11	1	1982	M
16154	21	Mehrzad	Madanchi	12	10	1982	M
55739	22	Vahid	Talebloo	26	5	1982	M
111	23	Masoud	Shojaei	9	6	1984	M
14267	2	Cristian	Zaccardo	21	12	1981	M
99473	3	Fabio	Grosso	28	11	1977	M
65802	4	Daniele	De Rossi	24	7	1983	M
26539	6	Andrea	Barzagli	8	5	1981	M
96512	9	Luca	Toni	26	5	1977	M
48645	11	Alberto	Gilardino	5	7	1982	M
88263	12	Angelo	Peruzzi	16	2	1970	M
69103	14	Marco	Amelia	2	4	1982	M
38599	15	Vincenzo	Iaquinta	21	11	1979	M
22378	16	Mauro	Camoranesi	4	10	1976	M
97154	17	Simone	Barone	30	4	1978	M
57529	20	Simone	Perrotta	17	9	1977	M
99537	21	Andrea	Pirlo	19	5	1979	M
70140	22	Massimo	Oddo	14	6	1976	M
31283	1	Jean-Jacques	Tizié	7	9	1972	M
48722	2	Kanga	Akalé	7	3	1981	M
8544	3	Arthur	Boka	2	4	1983	M
25398	4	Kolo	Touré	19	3	1981	M
48968	5	Didier	Zokora	14	12	1980	M
80902	6	Blaise	Kouassi	2	2	1975	M
14259	7	Emerse	Faé	24	1	1984	M
67250	8	Bonaventure	Kalou	12	1	1978	M
14175	9	Arouna	Koné	11	11	1983	M
58634	10	Gilles	Yapi Yapo	13	1	1982	M
99466	11	Didier	Drogba	11	3	1978	M
12127	12	Abdoulaye	Méïté	6	10	1980	M
97294	13	Marco	Zoro	27	12	1983	M
64184	14	Bakari	Koné	17	9	1981	M
93241	15	Aruna	Dindane	26	11	1980	M
51266	16	Gérard	Gnanhouan	12	2	1979	M
20335	17	Cyril	Domoraud	22	7	1971	M
98071	18	Abdul	Kader Keïta	6	8	1981	M
44934	19	Yaya	Touré	13	5	1983	M
75763	20	Guy	Demel	13	6	1981	M
92316	21	Emmanuel	Eboué	4	6	1983	M
55581	22	not applicable	Romaric	4	6	1983	M
30753	23	Boubacar	Barry	30	12	1979	M
65411	2	Teruyuki	Moniwa	8	9	1981	M
46091	3	Yūichi	Komano	25	7	1981	M
61292	4	Yasuhito	Endō	28	1	1980	M
56897	9	Naohiro	Takahara	4	6	1979	M
77277	10	Shunsuke	Nakamura	24	6	1978	M
17506	11	Seiichiro	Maki	7	8	1980	M
40995	12	Yoichi	Doi	25	7	1973	M
10636	16	Masashi	Oguro	4	5	1980	M
99888	19	Keisuke	Tsuboi	16	9	1979	M
15134	20	Keiji	Tamada	11	4	1980	M
87604	21	Akira	Kaji	13	1	1980	M
90430	22	Yuji	Nakazawa	25	2	1978	M
97434	3	Carlos	Salcido	2	4	1980	M
98486	5	Ricardo	Osorio	30	3	1980	M
30651	7	not applicable	Sinha	23	5	1976	M
73255	10	Guillermo	Franco	3	11	1976	M
5120	12	José	de Jesús Corona	26	1	1981	M
80826	13	Guillermo	Ochoa	13	7	1985	M
10860	14	Gonzalo	Pineda	19	10	1982	M
86098	15	José Antonio	Castro	11	8	1980	M
77467	16	Mario	Méndez	1	6	1979	M
89438	17	Francisco	Fonseca	2	10	1979	M
40312	18	Andrés	Guardado	28	9	1986	M
34977	19	Omar	Bravo	4	3	1980	M
11191	22	Francisco Javier	Rodríguez	20	10	1981	M
17445	23	Luis Ernesto	Pérez	12	1	1981	M
81414	2	Kew	Jaliens	15	9	1978	M
46895	3	Khalid	Boulahrouz	28	12	1981	M
40197	4	Joris	Mathijsen	5	4	1980	M
18113	6	Denny	Landzaat	6	5	1976	M
33312	7	Dirk	Kuyt	22	7	1980	M
3013	9	Ruud	van Nistelrooy	1	7	1976	M
68125	10	Rafael	van der Vaart	11	2	1983	M
23705	11	Arjen	Robben	23	1	1984	M
65694	12	Jan	Kromkamp	17	8	1980	M
28832	14	John	Heitinga	15	11	1983	M
13377	15	Tim	de Cler	8	11	1978	M
66598	16	Hedwiges	Maduro	13	2	1985	M
99934	17	Robin	van Persie	6	8	1983	M
69700	18	Mark	van Bommel	22	4	1977	M
63856	19	Jan	Vennegoor of Hesselink	7	11	1978	M
51336	20	Wesley	Sneijder	9	6	1984	M
17967	21	Ryan	Babel	19	12	1986	M
3558	22	Henk	Timmer	3	12	1971	M
36850	23	Maarten	Stekelenburg	22	9	1982	M
429	2	Jorge	Núñez	22	1	1978	M
42228	3	Delio	Toledo	2	10	1976	M
54903	7	Salvador	Cabañas	5	8	1980	M
44396	8	Édgar	Barreto	15	7	1984	M
53378	12	Derlis	Gómez	2	11	1972	M
30891	14	Paulo	da Silva	1	2	1980	M
22470	15	Julio César	Manzur	22	1	1981	M
78654	16	Cristian	Riveros	16	10	1982	M
51433	17	José	Montiel	19	3	1988	M
71995	18	Nelson Haedo	Valdez	28	11	1983	M
35595	19	Julio	dos Santos	7	5	1983	M
99403	20	Dante	López	16	8	1983	M
26126	22	Aldo	Bobadilla	20	4	1976	M
32695	1	Artur	Boruc	20	2	1980	M
63796	2	Mariusz	Jop	3	8	1978	M
10771	3	Seweryn	Gancarczyk	22	11	1981	M
12680	4	Marcin	Baszczyński	7	6	1977	M
24493	5	Kamil	Kosowski	30	8	1977	M
5425	7	Radosław	Sobolewski	13	12	1976	M
86811	10	Mirosław	Szymkowiak	12	11	1976	M
21451	11	Grzegorz	Rasiak	12	1	1979	M
34895	12	Tomasz	Kuszczak	23	3	1982	M
75168	13	Sebastian	Mila	10	7	1982	M
95900	15	Euzebiusz	Smolarek	9	1	1981	M
52481	16	Arkadiusz	Radomski	27	6	1977	M
2210	17	Dariusz	Dudka	9	12	1983	M
97704	18	Mariusz	Lewandowski	18	5	1979	M
37586	19	Bartosz	Bosacki	20	12	1975	M
41668	20	Piotr	Giza	28	2	1980	M
13524	21	Ireneusz	Jeleń	9	4	1981	M
57476	22	Łukasz	Fabiański	18	4	1985	M
67164	23	Paweł	Brożek	21	4	1983	M
16378	2	Paulo	Ferreira	18	1	1979	M
55321	4	Ricardo	Costa	16	5	1981	M
53943	5	Fernando	Meira	5	6	1978	M
80908	6	not applicable	Costinha	1	12	1974	M
32279	11	not applicable	Simão	31	10	1979	M
86534	12	not applicable	Quim	13	11	1975	M
28497	13	not applicable	Miguel	4	1	1980	M
62437	14	Nuno	Valente	12	9	1974	M
68375	15	Luís	Boa Morte	4	8	1977	M
37760	16	Ricardo	Carvalho	18	5	1978	M
70442	17	Cristiano	Ronaldo	5	2	1985	M
17581	18	not applicable	Maniche	11	11	1977	M
21434	19	not applicable	Tiago	2	5	1981	M
96343	20	not applicable	Deco	27	8	1977	M
55784	22	Paulo	Santos	11	12	1972	M
83900	23	Hélder	Postiga	2	8	1982	M
48279	4	Hamad	Al-Montashari	22	6	1982	M
84226	5	Naif	Al-Qadi	3	4	1979	M
21753	7	Mohammed	Ameen	29	4	1980	M
88984	11	Saad	Al-Harthi	3	2	1984	M
50973	14	Saud	Kariri	8	7	1980	M
58952	15	Ahmed	Al-Bahri	18	9	1980	M
66016	16	Khaled	Aziz	14	7	1981	M
60833	17	Mohamed	Al-Bishi	3	5	1987	M
33367	19	Mohammad	Massad	17	2	1983	M
87114	20	Yasser	Al-Qahtani	10	10	1982	M
95677	22	Mohammad	Khouja	15	3	1982	M
69611	23	Malek	Mouath	10	8	1981	M
34336	1	Dragoslav	Jevrić	8	7	1974	M
41907	2	Ivan	Ergić	21	1	1981	M
50226	3	Ivica	Dragutinović	13	11	1975	M
8415	4	Igor	Duljaj	29	10	1979	M
68901	5	Nemanja	Vidić	21	10	1981	M
41962	6	Goran	Gavrančić	2	8	1978	M
50012	7	Ognjen	Koroman	19	9	1978	M
37893	8	Mateja	Kežman	12	4	1979	M
33481	11	Predrag	Đorđević	4	8	1972	M
48430	12	Oliver	Kovačević	29	12	1974	M
58429	13	Dušan	Basta	18	8	1984	M
64659	14	Nenad	Đorđević	7	8	1979	M
79645	15	Milan	Dudić	1	11	1979	M
8113	16	Dušan	Petković	13	6	1974	M
85128	17	Albert	Nađ	29	10	1974	M
25611	18	Zvonimir	Vukić	19	7	1979	M
18094	19	Nikola	Žigić	25	9	1980	M
55456	20	Mladen	Krstajić	4	3	1974	M
87039	21	Danijel	Ljuboja	4	9	1978	M
5783	22	Saša	Ilić	30	12	1977	M
46403	23	Vladimir	Stojković	28	7	1983	M
94594	2	Young-chul	Kim	30	6	1976	M
61550	3	Dong-jin	Kim	29	1	1982	M
76780	6	Jin-kyu	Kim	16	2	1985	M
65040	8	Do-heon	Kim	14	7	1982	M
6608	10	Chu-young	Park	10	7	1985	M
89943	15	Ji-hoon	Baek	28	2	1985	M
4977	16	Kyung-ho	Chung	22	5	1980	M
92775	17	Ho	Lee	22	10	1984	M
56299	18	Sang-sik	Kim	17	12	1976	M
20248	19	Jae-jin	Cho	9	7	1981	M
50318	20	Yong-dae	Kim	11	10	1979	M
8539	21	Young-kwang	Kim	28	6	1983	M
55485	23	Won-hee	Cho	17	4	1983	M
63942	2	Míchel	Salgado	22	10	1975	M
28485	3	Mariano	Pernía	4	5	1977	M
15314	4	Carlos	Marchena	31	7	1979	M
71661	9	Fernando	Torres	20	3	1984	M
83711	10	José Antonio	Reyes	1	9	1983	M
25905	11	Luis	García	24	6	1978	M
13964	12	Antonio	López	13	9	1981	M
56330	13	Andrés	Iniesta	11	5	1984	M
73924	14	Xabi	Alonso	25	11	1981	M
89177	15	Sergio	Ramos	30	3	1986	M
82549	16	Marcos	Senna	17	7	1976	M
81297	18	Cesc	Fàbregas	4	5	1987	M
51440	20	not applicable	Juanito	23	7	1976	M
49097	21	David	Villa	3	12	1981	M
73344	22	Pablo	Ibáñez	3	8	1981	M
44334	23	Pepe	Reina	31	8	1982	M
75070	2	Mikael	Nilsson	24	6	1978	M
2115	12	John	Alvbåge	10	8	1982	M
20273	13	Petter	Hansson	14	12	1976	M
19165	14	Fredrik	Stenman	2	6	1983	M
44340	15	Karl	Svensson	21	3	1984	M
73608	16	Kim	Källström	24	8	1982	M
79017	17	Johan	Elmander	27	5	1981	M
65907	21	Christian	Wilhelmsson	8	12	1979	M
7148	22	Markus	Rosenberg	27	9	1982	M
95996	23	Rami	Shaaban	30	6	1975	M
38789	1	Pascal	Zuberbühler	8	1	1971	M
25758	2	Johan	Djourou	18	1	1987	M
82814	3	Ludovic	Magnin	20	4	1979	M
94161	4	Philippe	Senderos	14	2	1985	M
63929	5	Xavier	Margairaz	17	1	1984	M
17148	6	Johann	Vogel	8	3	1977	M
11817	7	Ricardo	Cabanas	17	1	1979	M
56006	8	Raphaël	Wicky	26	4	1977	M
61684	9	Alexander	Frei	15	7	1979	M
35674	10	Daniel	Gygax	28	8	1981	M
87221	11	Marco	Streller	18	6	1981	M
46325	12	Diego	Benaglio	8	9	1983	M
49127	13	Stéphane	Grichting	30	3	1979	M
6129	14	David	Degen	15	2	1983	M
35818	15	Blerim	Džemaili	12	4	1986	M
97143	16	Tranquillo	Barnetta	22	5	1985	M
10953	17	Christoph	Spycher	30	3	1978	M
46417	18	Mauro	Lustrinelli	26	2	1976	M
54713	19	Valon	Behrami	19	4	1985	M
37656	20	Patrick	Müller	17	12	1976	M
7302	21	Fabio	Coltorti	3	12	1980	M
59636	22	Hakan	Yakin	22	2	1977	M
10789	23	Philipp	Degen	15	2	1983	M
8028	1	Ouro-Nimini	Tchagnirou	31	12	1977	M
41085	2	Daré	Nibombé	16	6	1980	M
3523	3	Jean-Paul	Abalo	26	6	1975	M
48772	4	Emmanuel	Adebayor	26	2	1984	M
8365	5	Massamasso	Tchangai	8	8	1978	M
43931	6	Yao	Aziawonou	30	11	1979	M
57309	7	Moustapha	Salifou	1	6	1983	M
8310	8	Kuami	Agboh	28	12	1977	M
12652	9	Thomas	Dossevi	6	3	1979	M
64772	10	Chérif Touré	Mamam	13	1	1978	M
21511	11	Robert	Malm	21	8	1973	M
1401	12	Eric	Akoto	20	7	1980	M
58731	13	Richmond	Forson	23	5	1980	M
44097	14	Adékambi	Olufadé	7	1	1980	M
80410	15	Alaixys	Romao	18	1	1984	M
30416	16	Kossi	Agassa	2	7	1978	M
4210	17	Mohamed	Kader	8	4	1979	M
22298	18	Yao Junior	Sènaya	19	4	1984	M
77	19	Ludovic	Assemoassa	18	9	1980	M
53024	20	Affo	Erassa	19	2	1983	M
10224	21	Franck	Atsou	1	8	1978	M
60422	22	Kodjovi	Obilalé	8	10	1984	M
98500	23	Assimiou	Touré	1	1	1988	M
9117	1	Shaka	Hislop	22	2	1969	M
57974	2	Ian	Cox	25	3	1971	M
86728	3	Avery	John	18	6	1975	M
77807	4	Marvin	Andrews	22	12	1975	M
52480	5	Brent	Sancho	13	3	1977	M
49762	6	Dennis	Lawrence	1	8	1974	M
5918	7	Chris	Birchall	5	5	1984	M
40120	8	Cyd	Gray	21	11	1973	M
77687	9	Aurtis	Whitley	1	5	1977	M
61974	10	Russell	Latapy	2	8	1968	M
52850	11	Carlos	Edwards	24	10	1978	M
56282	12	Collin	Samuel	27	8	1981	M
78050	13	Cornell	Glen	21	10	1980	M
88830	14	Stern	John	30	10	1976	M
33665	15	Kenwyne	Jones	5	10	1984	M
3524	16	Evans	Wise	23	11	1973	M
23065	17	David Atiba	Charles	29	8	1977	M
22492	18	Densill	Theobald	27	6	1982	M
94201	19	Dwight	Yorke	3	11	1971	M
62644	20	Jason	Scotland	18	2	1979	M
74150	21	Kelvin	Jack	29	4	1976	M
34430	22	Clayton	Ince	12	7	1972	M
26454	23	Anthony	Wolfe	23	12	1983	M
31347	2	Karim	Essediri	29	7	1979	M
72448	3	Karim	Haggui	21	1	1984	M
96363	4	Alaeddine	Yahia	26	9	1981	M
33293	7	Haykel	Guemamdia	22	12	1981	M
69034	8	Mehdi	Nafti	28	11	1978	M
27618	9	Yassine	Chikhaoui	2	9	1986	M
9041	11	Francileudo	Santos	20	3	1979	M
61850	12	Jawhar	Mnari	8	11	1976	M
63068	14	Adel	Chedli	16	9	1976	M
66577	16	Adel	Nefzi	16	3	1974	M
54768	17	Chaouki	Ben Saada	1	7	1984	M
69430	18	David	Jemmali	13	12	1974	M
40581	19	Anis	Ayari	16	2	1982	M
61670	20	Hamed	Namouchi	12	1	1984	M
8678	21	Karim	Saidi	24	3	1983	M
79202	22	Hamdi	Kasraoui	18	1	1983	M
91602	23	Sofiane	Melliti	18	8	1978	M
91649	1	Oleksandr	Shovkovskyi	2	1	1975	M
17420	2	Andriy	Nesmachniy	28	2	1979	M
96896	3	Oleksandr	Yatsenko	24	2	1985	M
60675	4	Anatoliy	Tymoshchuk	30	3	1979	M
35676	5	Volodymyr	Yezerskiy	15	11	1976	M
7368	6	Andriy	Rusol	16	1	1983	M
86650	7	Andriy	Shevchenko	29	9	1976	M
56584	8	Oleh	Shelayev	5	11	1976	M
82307	9	Oleh	Husyev	25	4	1983	M
99083	10	Andriy	Voronin	21	7	1979	M
56553	11	Serhii	Rebrov	3	6	1974	M
37090	12	Andriy	Pyatov	28	6	1984	M
32374	13	Dmytro	Chyhrynskyi	7	11	1986	M
47335	14	Andriy	Husin	11	12	1972	M
69073	15	Artem	Milevskyi	12	1	1985	M
58919	16	Andriy	Vorobey	29	11	1978	M
27508	17	Vladyslav	Vashchuk	2	1	1975	M
60032	18	Serhiy	Nazarenko	16	2	1980	M
98387	19	Maksym	Kalynychenko	26	1	1979	M
55388	20	Oleksiy	Byelik	15	2	1981	M
67256	21	Ruslan	Rotan	29	10	1981	M
18200	22	Vyacheslav	Sviderskyi	1	1	1979	M
96162	23	Bohdan	Shust	4	3	1986	M
50522	1	Tim	Howard	6	3	1979	M
59999	2	Chris	Albright	14	1	1979	M
12548	3	Carlos	Bocanegra	25	5	1979	M
18672	8	Clint	Dempsey	9	3	1983	M
80859	9	Eddie	Johnson	31	3	1984	M
71080	11	Brian	Ching	24	5	1978	M
83190	13	Jimmy	Conrad	12	2	1977	M
60945	14	Ben	Olsen	3	5	1977	M
42535	15	Bobby	Convey	27	5	1983	M
92673	19	Marcus	Hahnemann	15	6	1972	M
87765	22	Oguchi	Onyewu	13	5	1982	M
24548	2	Eva	González	2	9	1987	F
65068	4	Gabriela	Chávez	9	4	1989	F
2875	5	Carmen	Brusca	7	11	1985	F
66590	7	Ludmila	Manicler	6	7	1987	F
24460	10	Emilia	Mendieta	4	4	1988	F
8904	13	Florencia	Quiñones	26	8	1986	F
24795	14	Catalina	Pérez	16	2	1989	F
80712	15	Florencia	Mandrile	10	12	1988	F
4287	16	Andrea	Ojeda	17	1	1985	F
5215	18	Belén	Potassa	12	12	1988	F
82027	19	Analía	Almeida	19	8	1985	F
92491	20	Mercedes	Pereyra	7	5	1987	F
69918	21	Elisabeth	Minnig	6	1	1987	F
14085	2	Kate	McShea	13	4	1983	F
42226	8	Caitlin	Munoz	4	10	1983	F
26286	9	Sarah	Walsh	11	1	1983	F
83079	11	Lisa	De Vanna	14	11	1984	F
91505	12	Kate	Gill	10	12	1984	F
15139	13	Thea	Slatyer	2	2	1983	F
87492	14	Collette	McCallum	26	3	1986	F
74624	15	Sally	Shipard	20	10	1987	F
82607	16	Lauren	Colthorpe	25	10	1985	F
94956	18	Lydia	Williams	13	5	1988	F
35812	19	Clare	Polkinghorne	1	2	1989	F
21039	20	Joanne	Burgess	23	9	1979	F
33547	21	Emma	Wirkus	11	1	1982	F
81163	2	not applicable	Elaine	1	11	1982	F
84724	3	not applicable	Aline	6	7	1982	F
61069	12	not applicable	Bárbara	4	7	1988	F
25746	17	not applicable	Daiane	15	4	1983	F
58459	20	not applicable	Ester	9	12	1982	F
50674	21	not applicable	Thaís	19	6	1987	F
2636	3	Melanie	Booth	24	8	1984	F
3906	4	Robyn	Gayle	31	10	1985	F
19025	9	Candace	Chapman	2	4	1983	F
62671	10	Martina	Franko	13	1	1976	F
27120	14	Melissa	Tancredi	27	12	1981	F
33304	16	Katie	Thorlakson	14	1	1985	F
95092	19	Sophie	Schmidt	28	6	1988	F
44161	21	Jodi-Ann	Robinson	17	4	1989	F
43215	1	Yanru	Zhang	10	1	1987	F
53317	2	Xinzhi	Weng	15	6	1988	F
54442	4	Kun	Wang	20	10	1985	F
48604	5	Xiaoli	Song	21	7	1981	F
57621	6	Caixia	Xie	17	2	1976	F
52970	10	Xiaoxu	Ma	5	6	1988	F
51360	13	Dongna	Li	6	12	1988	F
26568	15	Gaoping	Zhou	20	10	1986	F
85561	17	Sa	Liu	11	7	1987	F
23604	19	Ying	Zhang	27	6	1985	F
72394	20	Tong	Zhang	3	4	1984	F
74705	21	Meishuang	Xu	28	5	1986	F
58449	1	Heidi	Johansen	9	6	1983	F
82713	2	Mia	Olsen	15	10	1981	F
51843	4	Gitte	Andersen	28	4	1977	F
17894	5	Bettina	Falk	31	3	1981	F
11819	7	Cathrine	Paaske Sørensen	14	6	1978	F
24775	8	Julia	Rydahl Bukh	9	1	1982	F
5784	9	Maiken	Pape	20	2	1978	F
30396	12	Stine	Dimun	15	10	1979	F
20868	13	Johanna	Rasmussen	2	7	1983	F
6237	14	Dorte	Dalum Jensen	3	7	1978	F
60168	15	Mariann	Gajhede Knudsen	16	11	1984	F
36403	16	Tine	Cederkvist	21	3	1979	F
23254	17	Janne	Madsen	12	3	1978	F
74383	18	Christina	Ørntoft	2	7	1985	F
99432	19	Line	Røddik Hansen	31	1	1988	F
74183	20	Camilla	Sand Andersen	14	2	1986	F
22569	21	Susanne	Graversen	8	11	1984	F
40412	1	Rachel	Brown	2	7	1980	F
22178	2	Alex	Scott	14	10	1984	F
77877	3	Casey	Stoney	13	5	1982	F
73084	4	Katie	Chapman	15	6	1982	F
81136	5	Faye	White	2	2	1978	F
34666	7	Karen	Carney	1	8	1987	F
10986	8	Fara	Williams	25	1	1984	F
38733	9	Eniola	Aluko	21	2	1987	F
12357	10	Kelly	Smith	29	10	1978	F
38142	11	Rachel	Yankey	1	11	1979	F
45870	12	Anita	Asante	27	4	1985	F
55474	13	Siobhan	Chamberlain	15	8	1983	F
16452	14	Rachel	Unitt	5	6	1982	F
85483	15	Sue	Smith	24	11	1979	F
41187	16	Jill	Scott	2	2	1987	F
81958	17	Jody	Handley	12	3	1979	F
98538	18	Lianne	Sanderson	3	2	1988	F
88697	19	Vicky	Exley	22	10	1975	F
79856	20	Lindsay	Johnson	8	5	1980	F
78748	21	Carly	Telford	7	7	1987	F
96080	3	Saskia	Bartusiak	9	9	1982	F
59869	4	Babett	Peter	12	5	1988	F
67377	5	Annike	Krahn	1	7	1985	F
39260	7	Melanie	Behringer	18	11	1985	F
30564	11	Anja	Mittag	16	5	1985	F
95839	12	Ursula	Holl	26	6	1982	F
47092	14	Simone	Laudehr	12	7	1986	F
54473	19	Fatmire	Bajramaj	1	4	1988	F
50575	20	Petra	Wimbersky	9	11	1982	F
56710	4	Doreen	Awuah	12	12	1989	F
93979	7	Safia Abdul	Rahman	5	5	1986	F
68145	9	Anita	Amenuku	27	7	1985	F
68729	12	Olivia	Amoako	30	9	1985	F
1062	14	Rumanatu	Tahiru	4	6	1984	F
5170	17	Hamdya	Abass	1	8	1982	F
68309	18	Anita	Amankwa	2	9	1989	F
77841	21	Memuna	Darku	17	4	1979	F
38266	1	Miho	Fukumoto	2	10	1983	F
49475	3	Yukari	Kinga	2	5	1984	F
96331	14	Nayuha	Toyoda	15	9	1986	F
55574	15	Azusa	Iwashimizu	14	10	1986	F
20246	17	Yūki	Ōgimi	15	7	1987	F
86882	18	Shinobu	Ohno	23	1	1984	F
99210	19	Mizuho	Sakaguchi	15	10	1987	F
84771	20	Rumi	Utsugi	5	12	1988	F
43213	21	Misaki	Amano	22	4	1985	F
59575	1	Jenny	Bindon	25	2	1973	F
61084	2	Ria	Percival	7	12	1989	F
83259	3	Hannah	Bromley	15	11	1986	F
82898	4	Katie	Duncan	1	2	1988	F
393	5	Abby	Erceg	20	11	1989	F
46683	6	Rebecca	Smith	17	6	1981	F
13547	7	Zoe	Thompson	16	9	1983	F
11940	8	Hayley	Moorwood	13	2	1984	F
80895	10	Annalie	Longo	1	7	1991	F
21210	11	Marlies	Oostdam	29	7	1977	F
40693	12	Stephanie	Puckrin	22	8	1979	F
69129	13	Ali	Riley	30	10	1987	F
73751	14	Simone	Ferrara	7	6	1977	F
32154	15	Maia	Jackman	25	5	1975	F
80600	16	Emma	Humphries	14	6	1986	F
22277	17	Rebecca	Tegg	18	12	1985	F
58561	18	Priscilla	Duncan	19	5	1983	F
52525	19	Emily	McColl	1	11	1985	F
38007	20	Merissa	Smith	11	11	1990	F
40496	21	Rachel	Howard	30	11	1977	F
1039	3	Ayisat	Yusuf	6	3	1985	F
72499	6	Gift	Otuwe	15	7	1984	F
1517	9	Ogonna	Chukwudi	14	9	1988	F
19149	10	Rita	Chikwelu	6	3	1988	F
29682	11	Chi-Chi	Igbo	1	5	1986	F
65033	12	Tochukwu	Oluehi	2	5	1987	F
26654	13	Christie	George	10	5	1984	F
69273	16	Ulunma	Jerome	11	4	1988	F
16613	18	Cynthia	Uwak	15	7	1986	F
94784	19	Lilian	Cole	1	8	1985	F
95386	20	Maureen	Eke	19	12	1986	F
56097	21	Aladi	Ayegba	25	6	1986	F
30107	1	Un-hui	Phi	2	8	1985	F
93587	2	Kyong-hwa	Kim	28	3	1986	F
8347	3	Jong-ran	Om	10	10	1985	F
89322	4	Song-mi	Yun	28	1	1992	F
83860	6	Ok-sim	Kim	2	7	1987	F
96884	8	Son-hui	Kil	7	3	1986	F
7625	9	Un-suk	Ri	1	1	1986	F
96153	11	Un-byol	Ho	19	1	1992	F
476	14	Yong-ok	Jang	17	9	1982	F
68017	15	Kyong-sun	Sonu	28	9	1983	F
79610	16	Hye-ok	Kong	19	7	1983	F
83515	17	Yong-ae	Kim	7	3	1983	F
21807	18	Hyon-hi	Yun	9	9	1992	F
92164	19	Pok-sim	Jong	31	7	1985	F
33928	20	Myong-gum	Hong	10	7	1986	F
67990	21	Myong-hui	Jon	7	8	1986	F
68132	4	Ingvild	Stensland	3	8	1981	F
51925	5	Siri	Nordby	4	8	1978	F
38523	6	Camilla	Huse	31	8	1979	F
9212	9	Isabell	Herlovsen	23	6	1988	F
30339	10	Melissa	Wiik	7	2	1985	F
97621	11	Leni Larsen	Kaurin	21	3	1981	F
1929	12	Erika	Skarbø	12	6	1987	F
42549	13	Christine Colombo	Nilsen	30	4	1982	F
42222	14	Guro	Knutsen Mienna	10	1	1985	F
15475	15	Madeleine	Giske	14	9	1987	F
95127	17	Lene	Mykjåland	20	2	1987	F
8869	18	Marie	Knutsen	31	8	1982	F
25739	21	Lene	Storløkken	20	6	1981	F
27779	1	Hedvig	Lindahl	29	4	1983	F
48787	3	Stina	Segerström	17	6	1982	F
94354	5	Caroline	Seger	19	3	1985	F
66882	6	Sara	Thunebro	26	4	1979	F
96721	8	Lotta	Schelin	27	2	1984	F
85545	16	Anna	Paulson	29	2	1984	F
28917	17	Madelaine	Edlund	15	9	1985	F
52228	18	Nilla	Fischer	2	8	1984	F
40792	19	Charlotte	Rohlin	2	12	1980	F
5293	20	Linda	Forsberg	19	6	1985	F
51033	21	Kristin	Hammarström	29	3	1982	F
95448	2	Marian	Dalmy	25	11	1984	F
40936	5	Lindsay	Tarpley	22	9	1983	F
49030	6	Natasha	Kai	22	5	1983	F
25717	8	Tina	Ellertson	20	5	1982	F
54396	9	Heather	O'Reilly	2	1	1985	F
62104	11	Carli	Lloyd	16	7	1982	F
17276	12	Leslie	Osborne	27	5	1983	F
24266	14	Stephanie	Cox	3	4	1986	F
69030	17	Lori	Chalupny	29	1	1984	F
80833	18	Hope	Solo	30	7	1981	F
75460	19	Marci	Jobson	4	12	1975	F
49425	21	Nicole	Barnhart	10	10	1981	F
98886	1	Lounès	Gaouaoui	28	9	1977	M
21116	2	Madjid	Bougherra	7	10	1982	M
957	3	Nadir	Belhadj	18	6	1982	M
77742	4	Antar	Yahia	21	3	1982	M
19453	5	Rafik	Halliche	2	9	1986	M
30221	6	Yazid	Mansouri	25	2	1978	M
70903	7	Ryad	Boudebouz	19	2	1990	M
23484	8	Mehdi	Lacen	15	3	1984	M
22008	9	Abdelkader	Ghezzal	5	12	1984	M
44112	10	Rafik	Saïfi	7	2	1975	M
10693	11	Rafik	Djebbour	8	3	1984	M
92503	12	Habib	Bellaïd	28	3	1986	M
63647	13	Karim	Matmour	25	6	1985	M
9837	14	Abdelkader	Laïfaoui	29	7	1981	M
42107	15	Karim	Ziani	17	8	1982	M
17205	16	Faouzi	Chaouchi	5	12	1984	M
37702	17	Adlène	Guedioura	12	11	1985	M
21704	18	Carl	Medjani	15	5	1985	M
70560	19	Hassan	Yebda	14	5	1984	M
9059	20	Djamel	Mesbah	9	10	1984	M
46257	21	Foued	Kadir	5	12	1983	M
94880	22	Djamel	Abdoun	14	2	1986	M
596	23	Raïs	M'Bolhi	25	4	1986	M
70815	1	Diego	Pozo	16	2	1978	M
39810	2	Martín	Demichelis	20	12	1980	M
93262	3	Clemente	Rodríguez	31	7	1981	M
6108	5	Mario	Bolatti	17	2	1985	M
42113	7	Ángel	Di María	14	2	1988	M
29398	9	Gonzalo	Higuaín	10	12	1987	M
5459	12	Ariel	Garcé	14	7	1979	M
49114	15	Nicolás	Otamendi	12	2	1988	M
36870	16	Sergio	Agüero	2	6	1988	M
56859	17	Jonás	Gutiérrez	5	7	1983	M
60592	18	Martín	Palermo	7	11	1973	M
28014	19	Diego	Milito	12	6	1979	M
55451	21	Mariano	Andújar	30	7	1983	M
60541	22	Sergio	Romero	22	2	1987	M
91484	23	Javier	Pastore	20	6	1989	M
33989	12	Adam	Federici	31	1	1985	M
96211	14	Brett	Holman	27	3	1984	M
37275	15	Mile	Jedinak	3	8	1984	M
70545	16	Carl	Valeri	14	8	1984	M
31145	17	Nikita	Rukavytsya	22	6	1987	M
7864	18	Eugene	Galekovic	12	6	1981	M
64711	19	Richard	Garcia	4	9	1981	M
3552	21	David	Carney	30	11	1983	M
73512	22	Dario	Vidošić	8	4	1987	M
94551	2	not applicable	Maicon	26	7	1981	M
58840	5	Felipe	Melo	26	8	1983	M
86163	6	Michel	Bastos	2	8	1983	M
78264	7	not applicable	Elano	14	6	1981	M
98528	9	Luís	Fabiano	8	11	1980	M
27402	12	Heurelho	Gomes	15	2	1981	M
9441	13	Dani	Alves	6	5	1983	M
32798	15	Thiago	Silva	22	9	1984	M
74066	17	not applicable	Josué	19	7	1979	M
86499	18	not applicable	Ramires	24	3	1987	M
29075	19	Júlio	Baptista	1	10	1981	M
25449	21	not applicable	Nilmar	14	7	1984	M
61927	22	not applicable	Doni	22	10	1979	M
82456	23	not applicable	Grafite	2	4	1979	M
44116	2	Benoît	Assou-Ekotto	24	3	1984	M
93209	3	Nicolas	Nkoulou	27	3	1990	M
68512	5	Sébastien	Bassong	9	7	1986	M
99407	6	Alex	Song	9	9	1987	M
88732	7	Landry	N'Guémo	28	11	1985	M
96890	10	Achille	Emaná	5	6	1982	M
67012	11	Jean	Makoun	29	5	1983	M
47081	12	Gaëtan	Bong	25	4	1988	M
6117	13	Eric Maxim	Choupo-Moting	23	3	1989	M
86625	14	Aurélien	Chedjou	20	6	1985	M
10830	15	Pierre	Webó	20	1	1982	M
44262	16	Souleymanou	Hamidou	22	11	1973	M
53593	17	Mohammadou	Idrissou	8	3	1980	M
48455	18	Eyong	Enoh	23	3	1986	M
48783	19	Stéphane	Mbia	20	5	1986	M
48097	20	Georges	Mandjeck	9	12	1988	M
47974	21	Joël	Matip	8	8	1991	M
94440	22	Guy	N'dy Assembé	28	2	1986	M
53452	23	Vincent	Aboubakar	22	1	1992	M
89601	1	Claudio	Bravo	13	4	1983	M
98593	2	Ismael	Fuentes	4	8	1981	M
23300	3	Waldo	Ponce	4	12	1982	M
16376	4	Mauricio	Isla	12	6	1988	M
29404	5	Pablo	Contreras	11	9	1978	M
41671	6	Carlos	Carmona	21	2	1987	M
30014	7	Alexis	Sánchez	19	12	1988	M
41001	8	Arturo	Vidal	22	5	1987	M
66477	9	Humberto	Suazo	10	5	1981	M
65631	10	Jorge	Valdivia	19	10	1983	M
35574	11	Mark	González	10	7	1984	M
52362	12	Miguel	Pinto	4	7	1983	M
8305	13	Marco	Estrada	28	5	1983	M
96009	14	Matías	Fernández	15	5	1986	M
74480	15	Jean	Beausejour	1	6	1984	M
31755	16	Fabián	Orellana	27	1	1986	M
49014	17	Gary	Medel	3	8	1987	M
21890	18	Gonzalo	Jara	29	8	1985	M
67949	19	Gonzalo	Fierro	21	3	1983	M
39840	20	Rodrigo	Millar	3	11	1981	M
90807	21	Rodrigo	Tello	14	10	1979	M
8708	22	Esteban	Paredes	1	8	1980	M
11751	23	Luis	Marín	18	5	1983	M
14988	3	Simon	Kjær	26	3	1989	M
52264	4	Daniel	Agger	12	12	1984	M
93951	5	William	Kvist	24	2	1985	M
13831	6	Lars	Jacobsen	20	9	1979	M
18657	7	Daniel	Jensen	25	6	1979	M
38862	11	Nicklas	Bendtner	16	1	1988	M
47232	12	Thomas	Kahlenberg	20	3	1983	M
83625	13	Per	Krøldrup	31	7	1979	M
67264	14	Jakob	Poulsen	7	7	1983	M
89870	15	Simon	Poulsen	7	10	1984	M
83165	16	Stephan	Andersen	26	11	1981	M
45005	17	Mikkel	Beckmann	24	10	1983	M
5707	18	Søren	Larsen	6	9	1981	M
41303	20	Thomas	Enevoldsen	27	7	1987	M
50104	21	Christian	Eriksen	14	2	1992	M
23395	23	Patrick	Mtiliga	28	1	1981	M
43764	2	Glen	Johnson	23	8	1984	M
6000	5	Michael	Dawson	18	11	1983	M
84201	12	Robert	Green	18	1	1980	M
44282	13	Stephen	Warnock	12	12	1981	M
69235	14	Gareth	Barry	23	2	1981	M
41152	15	Matthew	Upson	18	4	1979	M
95616	16	James	Milner	4	1	1986	M
48335	17	Shaun	Wright-Phillips	25	10	1981	M
42890	19	Jermain	Defoe	7	10	1982	M
16073	20	Ledley	King	12	10	1980	M
64443	23	Joe	Hart	19	4	1987	M
30711	1	Hugo	Lloris	26	12	1986	M
69530	2	Bacary	Sagna	14	2	1983	M
94643	4	Anthony	Réveillère	10	11	1979	M
13394	6	Marc	Planus	7	3	1982	M
72795	8	Yoann	Gourcuff	11	7	1986	M
42706	11	André-Pierre	Gignac	5	12	1985	M
72916	13	Patrice	Evra	15	5	1981	M
9884	14	Jérémy	Toulalan	10	9	1983	M
69594	16	Steve	Mandanda	28	3	1985	M
33400	17	Sébastien	Squillaci	11	8	1980	M
82555	19	Abou	Diaby	11	5	1986	M
84312	20	Mathieu	Valbuena	28	9	1984	M
57240	21	Nicolas	Anelka	14	3	1979	M
77249	22	Gaël	Clichy	26	7	1985	M
38004	23	Cédric	Carrasso	30	12	1981	M
19408	1	Manuel	Neuer	27	3	1986	M
4201	4	Dennis	Aogo	14	1	1987	M
3879	5	Serdar	Tasci	24	4	1987	M
13029	6	Sami	Khedira	4	4	1987	M
12818	8	Mesut	Özil	15	10	1988	M
88148	9	Stefan	Kießling	25	1	1984	M
68199	12	Tim	Wiese	17	12	1981	M
28154	13	Thomas	Müller	13	9	1989	M
47255	14	Holger	Badstuber	13	3	1989	M
47324	15	Piotr	Trochowski	22	3	1984	M
39356	18	Toni	Kroos	4	1	1990	M
10713	19	not applicable	Cacau	27	3	1981	M
4224	20	Jérôme	Boateng	3	9	1988	M
97093	21	Marko	Marin	13	3	1989	M
78594	23	Mario	Gómez	10	7	1985	M
79898	1	Daniel	Agyei	10	11	1989	M
50270	6	Anthony	Annan	21	7	1986	M
43176	7	Samuel	Inkoom	1	6	1989	M
93750	8	Jonathan	Mensah	13	7	1990	M
69641	12	Prince	Tagoe	9	11	1986	M
1945	13	André	Ayew	17	12	1989	M
56448	15	Isaac	Vorsah	21	6	1988	M
29011	16	Stephen	Ahorlu	5	9	1988	M
79884	17	Ibrahim	Ayew	16	4	1988	M
65216	18	Dominic	Adiyiah	29	11	1989	M
56284	19	Lee	Addy	26	9	1985	M
6223	20	Quincy	Owusu-Abeyie	15	4	1986	M
39956	21	Kwadwo	Asamoah	9	12	1988	M
66316	23	Kevin-Prince	Boateng	6	3	1987	M
51633	1	Kostas	Chalkias	30	5	1974	M
70793	2	Giourkas	Seitaridis	4	6	1981	M
70421	3	Christos	Patsatzoglou	19	3	1979	M
69064	4	Nikos	Spyropoulos	10	10	1983	M
47188	5	Vangelis	Moras	26	8	1981	M
10140	6	Alexandros	Tziolis	13	2	1985	M
58348	7	Georgios	Samaras	21	2	1985	M
36090	8	Avraam	Papadopoulos	3	12	1984	M
32124	9	Angelos	Charisteas	9	2	1980	M
17698	10	Giorgos	Karagounis	6	3	1977	M
28140	11	Loukas	Vyntra	5	2	1981	M
83927	12	Alexandros	Tzorvas	12	8	1982	M
7928	13	Michalis	Sifakis	9	9	1984	M
75292	14	Dimitris	Salpingidis	18	8	1981	M
5210	15	Vasilis	Torosidis	10	6	1985	M
50181	16	Sotirios	Kyrgiakos	23	7	1979	M
56893	17	Theofanis	Gekas	23	5	1980	M
45647	18	Sotiris	Ninis	3	4	1990	M
11436	19	Sokratis	Papastathopoulos	9	6	1988	M
59270	20	Pantelis	Kapetanos	8	6	1983	M
52378	21	Kostas	Katsouranis	21	6	1979	M
8522	22	Stelios	Malezas	11	3	1985	M
84614	23	Sakis	Prittas	9	1	1979	M
14138	1	Ricardo	Canales	30	5	1982	M
53363	2	Osman	Chávez	29	7	1984	M
31125	3	Maynor	Figueroa	2	5	1983	M
23032	4	Johnny	Palacios	20	12	1986	M
82662	5	Víctor	Bernárdez	24	5	1982	M
45221	6	Hendry	Thomas	23	2	1985	M
50967	7	Ramón	Núñez	14	11	1984	M
15185	8	Wilson	Palacios	29	7	1984	M
59301	9	Carlos	Pavón	19	10	1973	M
73160	10	Jerry	Palacios	1	11	1981	M
54804	11	David	Suazo	5	11	1979	M
91430	12	Georgie	Welcome	9	3	1985	M
53060	13	Roger	Espinoza	25	10	1986	M
93922	14	Boniek	García	4	9	1984	M
88160	15	Walter	Martínez	29	3	1982	M
71236	16	Mauricio	Sabillón	11	11	1978	M
97689	17	Édgar	Álvarez	9	1	1980	M
93059	18	Noel	Valladares	3	5	1977	M
6476	19	Danilo	Turcios	8	5	1978	M
4726	20	Amado	Guevara	2	5	1976	M
57482	21	Emilio	Izaguirre	10	5	1986	M
81025	22	Donis	Escober	3	2	1981	M
7624	23	Sergio	Mendoza	23	5	1981	M
11109	2	Christian	Maggio	11	2	1982	M
54694	3	Domenico	Criscito	30	12	1986	M
92874	4	Giorgio	Chiellini	14	8	1984	M
47246	7	Simone	Pepe	30	8	1983	M
75306	10	Antonio	Di Natale	13	10	1977	M
30116	12	Federico	Marchetti	7	2	1983	M
36764	13	Salvatore	Bocchetti	30	11	1986	M
19910	14	Morgan	De Sanctis	26	3	1977	M
37848	15	Claudio	Marchisio	19	1	1986	M
6005	17	Angelo	Palombo	25	9	1981	M
1045	18	Fabio	Quagliarella	31	1	1983	M
27627	20	Giampaolo	Pazzini	2	8	1984	M
37678	22	Riccardo	Montolivo	18	1	1985	M
57248	23	Leonardo	Bonucci	1	5	1987	M
19422	2	Benjamin	Angoua	28	11	1986	M
4746	6	Steve	Gohouri	8	2	1981	M
63253	7	Seydou	Doumbia	31	12	1987	M
31976	8	Salomon	Kalou	5	8	1985	M
19801	9	Cheick	Tioté	21	6	1986	M
33586	10	not applicable	Gervinho	27	5	1987	M
50281	12	Jean-Jacques	Gosso	15	3	1983	M
77484	14	Emmanuel	Koné	31	12	1986	M
77464	16	Aristide	Zogbo	30	12	1981	M
59702	17	Siaka	Tiéné	22	3	1982	M
55416	22	Sol	Bamba	13	1	1985	M
64945	23	Daniel	Yeboah	13	11	1984	M
148	2	Yuki	Abe	6	9	1981	M
29462	4	Marcus Tulio	Tanaka	24	4	1981	M
26303	5	Yuto	Nagatomo	12	9	1986	M
35179	6	Atsuto	Uchida	27	3	1988	M
3497	8	Daisuke	Matsui	11	5	1981	M
84807	9	Shinji	Okazaki	16	4	1986	M
89840	12	Kisho	Yano	5	4	1984	M
28659	13	Daiki	Iwamasa	30	1	1982	M
16260	14	Kengo	Nakamura	31	10	1980	M
85824	15	Yasuyuki	Konno	25	1	1983	M
90491	16	Yoshito	Ōkubo	9	6	1982	M
91793	17	Makoto	Hasebe	18	1	1984	M
33175	18	Keisuke	Honda	13	6	1986	M
12781	19	Takayuki	Morimoto	7	5	1988	M
53272	21	Eiji	Kawashima	20	3	1983	M
80043	7	Pablo	Barrera	21	6	1987	M
2461	8	Israel	Castro	29	12	1980	M
68042	11	Carlos	Vela	1	3	1989	M
1835	12	Paul	Aguilar	6	3	1986	M
36515	14	Javier	Hernández	1	6	1988	M
21208	15	Héctor	Moreno	17	1	1988	M
85916	16	Efraín	Juárez	22	2	1988	M
77047	17	Giovani	dos Santos	11	5	1989	M
98210	19	Jonny	Magallón	21	11	1981	M
1987	20	Jorge	Torres Nilo	16	1	1988	M
44438	21	Adolfo	Bautista	15	5	1979	M
53231	22	Alberto	Medina	29	5	1983	M
21945	23	Luis Ernesto	Michel	21	7	1979	M
20084	2	Gregory	van der Wiel	3	2	1988	M
53668	8	Nigel	de Jong	30	11	1984	M
93449	14	Demy	de Zeeuw	26	5	1983	M
63744	15	Edson	Braafheid	8	4	1983	M
32095	16	Michel	Vorm	20	10	1983	M
12995	17	Eljero	Elia	13	2	1987	M
3298	18	Stijn	Schaars	11	1	1984	M
81141	20	Ibrahim	Afellay	2	4	1986	M
64344	21	Klaas-Jan	Huntelaar	12	8	1983	M
66870	22	Sander	Boschker	20	10	1970	M
60304	1	Mark	Paston	13	12	1976	M
72305	2	Ben	Sigmund	3	2	1981	M
10960	3	Tony	Lochhead	12	1	1982	M
57058	4	Winston	Reid	3	7	1988	M
95458	5	Ivan	Vicelich	3	9	1976	M
81126	6	Ryan	Nelsen	18	10	1977	M
53863	7	Simon	Elliott	10	6	1974	M
72098	8	Tim	Brown	6	3	1981	M
90145	9	Shane	Smeltz	29	9	1981	M
90951	10	Chris	Killen	8	10	1981	M
85046	11	Leo	Bertos	20	12	1981	M
45524	12	Glen	Moss	19	1	1983	M
92939	13	Andy	Barron	24	12	1980	M
20963	14	Rory	Fallon	20	3	1982	M
54658	15	Michael	McGlinchey	7	1	1987	M
76440	16	Aaron	Clapham	1	1	1987	M
86132	17	Dave	Mulligan	24	3	1982	M
15454	18	Andrew	Boyens	18	9	1983	M
84524	19	Tommy	Smith	31	3	1990	M
17136	20	Chris	Wood	7	12	1991	M
26059	21	Jeremy	Christie	22	5	1983	M
72611	22	Jeremy	Brockie	7	10	1987	M
48947	23	James	Bannatyne	30	6	1975	M
51705	3	Taye	Taiwo	16	4	1985	M
24770	6	Danny	Shittu	2	9	1980	M
98373	8	not applicable	Yakubu	22	11	1982	M
52510	9	Obafemi	Martins	28	10	1984	M
39485	10	Brown	Ideye	10	10	1988	M
70006	11	Peter	Odemwingie	15	7	1981	M
98626	12	Kalu	Uche	15	11	1982	M
4333	13	Ayila	Yussuf	4	11	1984	M
34118	14	Sani	Kaita	2	5	1986	M
98826	15	Lukman	Haruna	4	12	1990	M
65327	17	Chidi	Odiah	17	12	1983	M
4567	18	Victor	Obinna	25	3	1987	M
62448	19	Chinedu	Obasi	1	6	1986	M
96711	20	Dickson	Etuhu	8	6	1982	M
45065	21	Elderson	Echiéjilé	20	1	1988	M
42799	22	Dele	Adeleye	25	12	1988	M
73175	23	Dele	Aiyenugba	20	11	1983	M
8689	1	Myong-guk	Ri	9	9	1986	M
44308	2	Jong-hyok	Cha	25	9	1985	M
66310	3	Jun-il	Ri	24	8	1987	M
56547	4	Nam-chol	Pak	2	7	1985	M
72474	5	Kwang-chon	Ri	4	9	1985	M
8049	6	Kum-il	Kim	10	10	1987	M
84945	7	Chol-hyok	An	27	6	1987	M
1454	8	Yun-nam	Ji	20	11	1976	M
4397	9	Tae-se	Jong	2	3	1984	M
57041	10	Yong-jo	Hong	22	5	1982	M
91408	11	In-guk	Mun	29	9	1978	M
92121	12	Kum-chol	Choe	9	2	1987	M
35746	13	Chol-jin	Pak	5	9	1985	M
47780	14	Nam-Chol	Pak	3	10	1988	M
2525	15	Yong-jun	Kim	19	7	1983	M
98982	16	Song-chol	Nam	7	5	1982	M
16478	17	Yong-hak	An	25	10	1978	M
42392	18	Myong-gil	Kim	16	10	1984	M
40949	19	Chol-myong	Ri	18	2	1988	M
80634	20	Myong-won	Kim	15	7	1983	M
79720	21	Kwang-hyok	Ri	17	8	1987	M
49251	22	Kyong-il	Kim	11	12	1988	M
79551	23	Il-gwan	Jong	30	10	1992	M
95038	2	Darío	Verón	26	6	1979	M
53028	3	Claudio	Morel	2	2	1978	M
30381	7	Óscar	Cardozo	20	5	1983	M
68929	10	Édgar	Benítez	8	11	1987	M
33360	11	Jonathan	Santana	19	10	1981	M
35934	12	Diego	Barreto	16	7	1981	M
18210	13	Enrique	Vera	10	3	1979	M
21823	15	Víctor	Cáceres	25	3	1985	M
6285	17	Aureliano	Torres	16	6	1982	M
50699	18	Nelson	Valdez	28	11	1983	M
41357	19	Lucas	Barrios	13	11	1984	M
37133	20	Néstor	Ortigoza	7	10	1984	M
87859	21	Antolín	Alcaraz	30	7	1982	M
21518	23	Rodolfo	Gamarra	10	12	1988	M
37990	1	not applicable	Eduardo	19	9	1982	M
76960	2	Bruno	Alves	27	11	1981	M
4367	4	not applicable	Rolando	31	8	1985	M
8069	5	not applicable	Duda	27	6	1980	M
47801	8	Pedro	Mendes	26	2	1979	M
28404	9	not applicable	Liédson	17	12	1977	M
95172	10	not applicable	Danny	7	8	1983	M
27059	12	not applicable	Beto	1	5	1982	M
98693	14	Miguel	Veloso	11	5	1986	M
81972	15	not applicable	Pepe	26	2	1983	M
88101	16	Raul	Meireles	17	3	1983	M
11629	17	Rúben	Amorim	27	1	1985	M
14428	18	Hugo	Almeida	23	5	1984	M
6977	22	Daniel	Fernandes	25	9	1983	M
92000	23	Fábio	Coentrão	11	3	1988	M
39341	2	Antonio	Rukavina	26	1	1984	M
33059	3	Aleksandar	Kolarov	10	11	1985	M
85465	4	Gojko	Kačar	26	1	1987	M
95482	6	Branislav	Ivanović	22	2	1984	M
25507	7	Zoran	Tošić	28	4	1987	M
40791	8	Danko	Lazović	17	5	1983	M
7371	9	Marko	Pantelić	15	9	1978	M
39459	11	Nenad	Milijaš	30	4	1983	M
38928	12	Bojan	Isailović	25	3	1980	M
32588	13	Aleksandar	Luković	23	10	1982	M
56515	14	Milan	Jovanović	18	4	1981	M
59023	16	Ivan	Obradović	25	7	1988	M
23735	17	Miloš	Krasić	1	11	1984	M
71962	18	Miloš	Ninković	25	12	1984	M
30803	19	Radosav	Petrović	8	3	1989	M
47415	20	Neven	Subotić	10	12	1988	M
81872	21	Dragan	Mrđa	23	1	1984	M
88851	22	Zdravko	Kuzmanović	22	9	1987	M
28333	23	Anđelko	Đuričić	21	11	1980	M
83904	1	Ján	Mucha	5	12	1982	M
55404	2	Peter	Pekarík	30	10	1986	M
57606	3	Martin	Škrtel	15	12	1984	M
51100	4	Marek	Čech	26	1	1983	M
30935	5	Radoslav	Zabavník	16	9	1980	M
37913	6	Zdeno	Štrba	9	6	1976	M
57948	7	Vladimír	Weiss	30	11	1989	M
26673	8	Ján	Kozák	22	4	1980	M
26852	9	Stanislav	Šesták	16	12	1982	M
81950	10	Marek	Sapara	31	7	1982	M
14764	11	Róbert	Vittek	1	4	1982	M
24713	12	Dušan	Perniš	28	11	1984	M
18604	13	Filip	Hološko	17	1	1984	M
82522	14	Martin	Jakubko	26	2	1980	M
78836	15	Miroslav	Stoch	19	10	1989	M
88680	16	Ján	Ďurica	10	12	1981	M
73975	17	Marek	Hamšík	27	7	1987	M
63023	18	Erik	Jendrišek	26	10	1986	M
18379	19	Juraj	Kucka	26	2	1987	M
40368	20	Kamil	Kopúnek	18	5	1984	M
75191	21	Kornel	Saláta	4	1	1985	M
77979	22	Martin	Petráš	2	11	1979	M
55017	23	Dušan	Kuciak	21	5	1985	M
80179	1	Samir	Handanović	14	7	1984	M
33677	2	Mišo	Brečko	1	5	1984	M
46048	3	Elvedin	Džinić	25	8	1985	M
10829	4	Marko	Šuler	9	3	1983	M
68662	5	Boštjan	Cesar	9	7	1982	M
68982	6	Branko	Ilić	6	2	1983	M
14953	7	Nejc	Pečnik	3	1	1986	M
17662	8	Robert	Koren	20	9	1980	M
1012	9	Zlatan	Ljubijankić	15	12	1983	M
20008	10	Valter	Birsa	7	8	1986	M
58094	11	Milivoje	Novaković	18	5	1979	M
15218	12	Jasmin	Handanović	28	1	1978	M
65942	13	Bojan	Jokić	17	5	1986	M
21784	14	Zlatko	Dedić	10	5	1984	M
76597	15	Rene	Krhin	21	5	1990	M
78416	16	Aleksander	Šeliga	1	2	1980	M
91038	17	Andraž	Kirm	6	9	1984	M
6159	18	Aleksandar	Radosavljević	25	4	1979	M
38988	19	Suad	Fileković	16	9	1978	M
75452	20	Andrej	Komac	4	12	1979	M
1978	21	Dalibor	Stevanović	27	9	1984	M
548	22	Matej	Mavrič	29	1	1979	M
75538	23	Tim	Matavž	13	1	1989	M
73468	1	Moeneeb	Josephs	19	5	1980	M
94009	2	Siboniso	Gaxa	6	4	1984	M
37930	3	Tsepo	Masilela	5	5	1985	M
6967	5	Anele	Ngcongca	20	10	1987	M
60414	7	Lance	Davids	11	4	1985	M
31160	8	Siphiwe	Tshabalala	25	9	1984	M
39078	9	Katlego	Mphela	29	11	1984	M
26472	11	Teko	Modise	22	12	1982	M
37166	12	Reneilwe	Letsholonyane	9	6	1982	M
92279	13	Kagisho	Dikgacoi	24	11	1984	M
89889	14	Matthew	Booth	14	3	1977	M
44682	15	Lucas	Thwala	19	10	1981	M
38574	16	Itumeleng	Khune	20	6	1987	M
36316	17	Bernard	Parker	16	3	1986	M
22568	19	Surprise	Moriri	20	3	1980	M
61943	20	Bongani	Khumalo	6	1	1987	M
22488	21	Siyabonga	Sangweni	29	9	1981	M
61610	22	Shu-Aib	Walters	26	12	1981	M
39008	23	Thanduyise	Khuboni	23	5	1986	M
61649	2	Beom-seok	Oh	29	7	1984	M
96457	3	Hyung-il	Kim	27	4	1984	M
16580	4	Yong-hyung	Cho	3	11	1983	M
16139	6	Bo-kyung	Kim	6	10	1989	M
47942	8	Jung-woo	Kim	9	5	1982	M
47809	11	Seung-yeoul	Lee	6	3	1989	M
30708	13	Jae-sung	Kim	3	10	1983	M
7494	14	Jung-soo	Lee	8	1	1980	M
48433	16	Sung-yueng	Ki	24	1	1989	M
40927	17	Chung-yong	Lee	2	7	1988	M
88939	18	Sung-ryong	Jung	4	1	1985	M
32822	19	Ki-hun	Yeom	30	3	1983	M
15739	23	Min-soo	Kang	14	2	1986	M
24647	2	Raúl	Albiol	4	9	1985	M
64348	3	Gerard	Piqué	2	2	1987	M
47753	11	Joan	Capdevila	3	2	1978	M
51931	12	Víctor	Valdés	14	1	1982	M
47597	13	Juan	Mata	28	4	1988	M
28010	16	Sergio	Busquets	16	7	1988	M
94275	17	Álvaro	Arbeloa	17	1	1983	M
78418	18	not applicable	Pedro	28	7	1987	M
38283	19	Fernando	Llorente	26	2	1985	M
5758	20	Javi	Martínez	2	9	1988	M
64102	21	David	Silva	8	1	1986	M
69284	22	Jesús	Navas	21	11	1985	M
9988	2	Stephan	Lichtsteiner	16	1	1984	M
62393	5	Steve	von Bergen	10	6	1983	M
24458	6	Benjamin	Huggel	7	7	1977	M
9596	8	Gökhan	Inler	27	6	1984	M
27813	10	Blaise	Nkufo	25	5	1975	M
75487	12	Marco	Wölfli	22	8	1982	M
71652	14	Marco	Padalino	8	12	1983	M
77553	16	Gélson	Fernandes	2	9	1986	M
9704	17	Reto	Ziegler	16	1	1986	M
4767	18	Albert	Bunjaku	29	11	1983	M
84535	19	Eren	Derdiyok	12	6	1988	M
31553	20	Pirmin	Schwegler	9	3	1987	M
29799	21	Johnny	Leoni	30	6	1984	M
31548	22	Mario	Eggimann	24	1	1981	M
39460	23	Xherdan	Shaqiri	10	10	1991	M
71113	2	Jonathan	Spector	1	3	1986	M
97258	4	Michael	Bradley	31	7	1987	M
72039	9	Herculez	Gomez	6	4	1982	M
88370	11	Stuart	Holden	1	8	1985	M
56817	12	Jonathan	Bornstein	7	11	1984	M
64198	13	Ricardo	Clark	10	3	1983	M
15091	14	Edson	Buddle	21	5	1981	M
78640	15	Jay	DeMerit	4	12	1979	M
55538	16	José Francisco	Torres	29	10	1987	M
7475	17	Jozy	Altidore	6	11	1989	M
58476	18	Brad	Guzan	9	9	1984	M
48341	19	Maurice	Edu	18	4	1986	M
36179	20	Robbie	Findley	4	8	1985	M
1212	21	Clarence	Goodson	17	5	1982	M
9461	22	Benny	Feilhaber	19	1	1985	M
10014	1	Fernando	Muslera	16	6	1986	M
89878	2	Diego	Lugano	2	11	1980	M
78440	3	Diego	Godín	16	2	1986	M
95196	4	Jorge	Fucile	19	11	1984	M
78735	5	Walter	Gargano	23	7	1984	M
92649	6	Mauricio	Victorino	11	10	1982	M
59138	7	Edinson	Cavani	14	2	1987	M
50741	8	Sebastián	Eguren	8	1	1981	M
30486	9	Luis	Suárez	24	1	1987	M
11075	11	Álvaro	Pereira	28	11	1985	M
91301	12	Juan	Castillo	17	4	1978	M
36662	14	Nicolás	Lodeiro	21	3	1989	M
53254	15	Diego	Pérez	18	5	1980	M
41944	16	Maxi	Pereira	8	6	1984	M
80668	17	Egidio	Arévalo Ríos	1	1	1982	M
46031	18	Ignacio	González	14	5	1982	M
87316	19	Andrés	Scotti	14	12	1975	M
99965	20	Álvaro	Fernández	11	10	1985	M
88751	21	Sebastián	Fernández	23	5	1985	M
74058	22	Martín	Cáceres	7	4	1987	M
59802	23	Martín	Silva	25	3	1983	M
86560	2	Teigen	Allen	12	2	1994	F
77401	3	Kim	Carroll	2	9	1987	F
60374	5	Laura	Alleway	28	11	1989	F
24314	6	Ellyse	Perry	3	11	1990	F
81723	8	Elise	Kellond-Knight	10	8	1990	F
87785	9	Caitlin	Foord	11	11	1994	F
89301	10	Servet	Uzunlar	8	3	1989	F
58730	12	Emily	van Egmond	12	7	1993	F
78451	13	Tameka	Yallop	16	6	1991	F
77133	17	Kyah	Simon	25	6	1991	F
36992	19	Leena	Khamis	19	6	1986	F
76435	20	Sam	Kerr	10	9	1993	F
82430	21	Casey	Dumont	25	1	1992	F
26798	2	not applicable	Maurine	14	1	1986	F
42763	9	not applicable	Beatriz	17	12	1993	F
82497	13	not applicable	Érika	4	2	1988	F
6224	14	not applicable	Fabiana	4	8	1989	F
51448	15	not applicable	Francielle	18	10	1989	F
51943	17	not applicable	Daniele	2	4	1983	F
51290	18	Thaís	Guedes	20	1	1993	F
11711	20	not applicable	Roseane	23	7	1985	F
36606	21	Thaís	Picarte	19	6	1987	F
59568	2	Emily	Zurrer	12	7	1987	F
7876	3	Kelly	Parker	8	3	1981	F
96648	6	Kaylyn	Kyle	6	10	1988	F
36065	11	Desiree	Scott	31	7	1987	F
96459	15	Christina	Julien	6	5	1988	F
96231	16	Jonelle	Filigno	24	9	1990	F
24924	19	Chelsea	Stewart	28	4	1990	F
45538	20	Marie-Ève	Nault	16	2	1982	F
47418	21	Stephanie	Labbé	10	10	1986	F
89708	1	Yineth	Varón	23	6	1982	F
78876	2	Yuli	Muñoz	18	3	1989	F
92991	3	Natalia	Gaitán	3	4	1991	F
68128	4	Diana	Ospina	3	3	1989	F
137	5	Nataly	Arias	2	4	1986	F
24999	6	Daniela	Montoya	22	8	1990	F
76437	7	Catalina	Usme	25	12	1989	F
6901	8	Andrea	Peralta	9	5	1988	F
3422	9	Carmen	Rodallega	15	7	1983	F
29031	10	Yoreli	Rincón	27	7	1993	F
64079	11	Liana	Salazar	16	9	1992	F
97803	12	Sandra	Sepúlveda	3	3	1988	F
4625	13	Yulieth	Domínguez	6	9	1993	F
69868	14	Kelis	Peduzine	21	4	1983	F
15347	15	Tatiana	Ariza	21	2	1991	F
24913	16	Lady	Andrade	10	1	1992	F
9925	17	Ingrid	Vidal	22	4	1991	F
46202	18	Katerin	Castro	21	11	1991	F
36367	19	Fátima	Montaño	2	10	1984	F
85632	20	Oriánica	Velásquez	1	8	1989	F
40025	21	Alejandra	Velasco	23	8	1985	F
90789	1	Karen	Bardsley	14	10	1984	F
65975	7	Jessica	Clarke	5	5	1989	F
84864	9	Ellen	White	9	5	1989	F
47576	15	Sophie	Bradley	5	5	1989	F
30706	16	Steph	Houghton	23	4	1988	F
69145	17	Laura	Bassett	2	8	1983	F
64295	19	Dunia	Susi	10	8	1987	F
35919	20	Claire	Rafferty	11	1	1989	F
83750	1	not applicable	Mirian	25	2	1982	F
36010	2	not applicable	Bruna	12	5	1984	F
94069	3	not applicable	Dulce	18	1	1982	F
15903	4	Carol	Carioca	18	2	1983	F
325	5	not applicable	Cris	12	12	1985	F
67928	6	not applicable	Vânia	9	11	1980	F
9953	7	Blessing	Diala	8	12	1989	F
30247	8	Emiliana	Mangue	4	12	1991	F
3224	9	Dorine	Chuigoué	28	11	1988	F
37720	10	Genoveva	Añonman	19	4	1989	F
96775	11	Natalia	Abeso	5	9	1986	F
21565	12	Sinforosa	Eyang	26	4	1994	F
43699	13	Haoua	Yao	2	7	1979	F
24534	14	not applicable	Jumária	8	5	1979	F
18006	15	Gloria	Chinasa	8	12	1987	F
93603	16	not applicable	Lucrecia	24	10	1988	F
9646	17	not applicable	Tiga	16	4	1983	F
77881	18	María	Rosa	10	10	1982	F
89658	19	not applicable	Fatoumata	27	3	1994	F
39140	20	Christelle	Nyepel	16	1	1995	F
1321	21	Laetitia	Chapeh	7	4	1987	F
26403	1	Céline	Deville	24	1	1982	F
32017	2	Wendie	Renard	20	7	1990	F
3183	3	Laure	Boulleau	22	10	1986	F
4863	5	Ophélie	Meilleroux	18	1	1984	F
81637	7	Corine	Franco	5	10	1983	F
70239	9	Eugénie	Le Sommer	18	5	1989	F
72635	10	Camille	Abily	5	12	1984	F
26793	11	Laure	Lepailleur	7	3	1985	F
64	12	Élodie	Thomis	13	8	1986	F
38368	13	Caroline	Pizzala	23	11	1987	F
63892	14	Louisa	Nécib	23	1	1987	F
81978	15	Élise	Bussaglia	24	9	1985	F
23859	17	Gaëtane	Thiney	28	10	1985	F
89379	18	Marie-Laure	Delie	29	1	1988	F
3998	19	Sandrine	Brétigny	2	7	1984	F
30046	21	Laëtitia	Philippe	30	4	1991	F
21392	2	Bianca	Schmidt	23	1	1990	F
80216	11	Alexandra	Popp	6	4	1991	F
66612	13	Célia	Šašić	27	6	1988	F
34124	14	Kim	Kulig	9	4	1990	F
59795	15	Verena	Schweers	22	5	1989	F
37178	20	Lena	Goeßling	8	3	1986	F
78023	21	Almuth	Schult	9	2	1991	F
90878	4	Saki	Kumagai	17	10	1990	F
79593	9	Nahomi	Kawasumi	23	9	1985	F
66855	14	Megumi	Kamionobe	15	3	1986	F
75658	15	Aya	Sameshima	16	6	1987	F
82534	16	Asuna	Tanaka	23	4	1988	F
46447	19	Megumi	Takase	10	11	1990	F
26643	20	Mana	Iwabuchi	18	3	1993	F
84176	21	Ayumi	Kaihori	4	9	1986	F
64032	1	Erika	Vanegas	7	7	1988	F
16304	2	Kenti	Robles	15	2	1991	F
73064	3	Marlene	Sandoval	18	1	1984	F
40448	4	Alina	Garciamendez	16	4	1991	F
4339	5	Natalie	Vinti	2	1	1988	F
3827	6	Natalie	Garcia	30	1	1990	F
31874	7	Evelyn	López	25	12	1978	F
93696	8	Lupita	Worbis	12	12	1983	F
36428	10	Dinora	Garza	24	1	1988	F
99179	11	Nayeli	Rangel	28	2	1992	F
20882	12	Pamela	Tajonar	2	12	1984	F
53234	13	Liliana	Mercado	22	10	1988	F
70528	14	Mónica	Alvarado	11	1	1991	F
64777	15	Luz	Saucedo	14	12	1983	F
93676	16	Charlyn	Corral	11	9	1991	F
37915	17	Teresa	Noyola	15	4	1990	F
32979	18	Verónica	Pérez	18	5	1988	F
3700	19	Mónica	Ocampo	4	1	1987	F
18004	20	Cecilia	Santiago	19	10	1994	F
40788	21	Stephany	Mayor	23	9	1991	F
54971	3	Anna	Green	20	8	1990	F
57283	9	Amber	Hearn	28	11	1984	F
24335	10	Sarah	Gregorius	6	8	1987	F
32271	11	Kirsty	Yallop	4	11	1986	F
83018	12	Betsy	Hassett	4	8	1990	F
82057	13	Rosie	White	6	6	1993	F
43463	14	Sarah	McLaughlin	3	6	1991	F
41881	15	Emma	Kete	1	9	1987	F
44115	17	Hannah	Wilkinson	28	5	1992	F
19118	18	Katie	Bowen	15	4	1994	F
47827	19	Kristy	Hill	1	7	1979	F
62775	20	Aroon	Clansey	12	2	1986	F
51933	21	Erin	Nayler	17	4	1992	F
87413	2	Rebecca	Kalu	12	6	1990	F
23374	3	Osinachi	Ohale	21	12	1991	F
79213	6	Helen	Ukaonu	17	5	1991	F
23667	8	Ebere	Orji	23	12	1992	F
67645	9	Desire	Oparanozie	17	12	1993	F
71274	11	Glory	Iroka	3	1	1990	F
98662	12	Sarah	Michael	22	7	1990	F
9202	15	Josephine	Chukwunonye	19	3	1992	F
86061	17	Francisca	Ordega	19	10	1993	F
45537	19	Uchechi	Sunday	9	9	1994	F
94180	20	Amenze	Aighewi	21	11	1991	F
53773	21	Alaba	Jonathan	1	6	1992	F
97038	1	Myong-hui	Hong	4	9	1991	F
28988	2	Hong-yon	Jon	11	6	1992	F
19575	4	Myong-gum	Kim	4	11	1990	F
76169	6	Sol-hui	Paek	20	3	1994	F
88077	8	Su-gyong	Kim	4	1	1995	F
96127	9	Un-sim	Ra	2	7	1988	F
13512	10	Yun-mi	Jo	5	1	1987	F
73131	11	Ye-gyong	Ri	26	10	1989	F
43034	12	Myong-hwa	Jon	9	8	1993	F
1735	13	Un-ju	Kim	9	4	1993	F
57216	14	Chung-sim	Kim	27	11	1990	F
96141	15	Jong-hui	Yu	21	3	1986	F
71871	17	Un-hyang	Ri	15	5	1988	F
89048	18	Chol-ok	Kim	15	10	1994	F
85229	19	Mi-gyong	Choe	17	1	1991	F
72263	20	Song-hwa	Kwon	5	2	1992	F
70524	21	Jin-sim	Ri	29	5	1991	F
58533	1	Ingrid	Hjelmseth	10	4	1980	F
54146	2	Nora	Holstad Berge	26	3	1987	F
74073	3	Maren	Mjelde	6	11	1989	F
5942	5	Marita Skammelsrud	Lund	29	1	1989	F
29295	6	Kristine	Minde	8	8	1992	F
8190	8	Runa	Vikestad	13	8	1984	F
66982	10	Cecilie	Pedersen	14	9	1990	F
78983	14	Gry Tofte	Ims	2	3	1986	F
820	15	Hedda Strand	Gardsjord	28	6	1982	F
38110	16	Elise	Thorsnes	14	8	1988	F
48031	19	Emilie	Haavi	16	6	1992	F
88468	20	Ingrid	Ryland	29	5	1989	F
8692	21	Caroline	Knutsen	21	11	1983	F
10056	3	Linda	Sembrant	15	5	1987	F
98700	4	Annica	Svensson	3	3	1983	F
49071	9	Jessica	Landström	12	12	1984	F
27729	10	Sofia	Jakobsson	23	4	1990	F
56321	11	Antonia	Göransson	16	9	1990	F
83862	13	Lina	Nilsson	17	6	1987	F
71934	17	Lisa	Dahlkvist	6	2	1987	F
16359	20	Marie	Hammarström	29	3	1982	F
26000	2	Heather	Mitts	9	6	1978	F
64276	4	Becky	Sauerbrunn	6	6	1985	F
72568	5	Kelley	O'Hara	4	8	1988	F
72716	6	Amy	LePeilbet	12	3	1982	F
89510	8	Amy	Rodriguez	17	2	1987	F
45187	11	Ali	Krieger	28	7	1984	F
81449	12	Lauren	Holiday	30	9	1987	F
37034	13	Alex	Morgan	2	7	1989	F
9273	15	Megan	Rapinoe	5	7	1985	F
12112	16	Lori	Lindsey	19	3	1980	F
35525	17	Tobin	Heath	29	5	1988	F
76699	19	Rachel	Buehler	26	8	1985	F
29767	21	Jillian	Loyden	25	5	1985	F
96937	1	Cédric	Si Mohamed	9	1	1985	M
55717	3	Faouzi	Ghoulam	1	2	1991	M
41251	4	Essaïd	Belkalem	1	1	1989	M
31598	9	Nabil	Ghilas	20	4	1990	M
12165	10	Sofiane	Feghouli	26	12	1989	M
24983	11	Yacine	Brahimi	8	2	1990	M
59199	13	Islam	Slimani	18	6	1988	M
96340	14	Nabil	Bentaleb	24	11	1994	M
63360	15	Hillal	Soudani	25	11	1987	M
52593	16	Mohamed	Zemmamouche	19	3	1985	M
98016	17	Liassine	Cadamuro-Bentaïba	5	3	1988	M
59147	18	Abdelmoumene	Djabou	31	1	1987	M
83421	19	Saphir	Taïder	29	2	1992	M
58383	20	Aïssa	Mandi	22	10	1991	M
91590	21	Riyad	Mahrez	21	2	1991	M
9673	22	Mehdi	Mostefa	30	8	1983	M
61051	2	Ezequiel	Garay	10	10	1986	M
69606	3	Hugo	Campagnaro	27	6	1980	M
96639	4	Pablo	Zabaleta	16	1	1985	M
51894	5	Fernando	Gago	10	4	1986	M
38647	6	Lucas	Biglia	30	1	1986	M
69019	8	Enzo	Pérez	22	2	1986	M
86028	12	Agustín	Orión	26	7	1981	M
29672	13	Augusto	Fernández	10	4	1986	M
18222	16	Marcos	Rojo	20	3	1990	M
72244	17	Federico	Fernández	21	2	1989	M
58741	19	Ricky	Álvarez	12	4	1988	M
69953	22	Ezequiel	Lavezzi	3	5	1985	M
38424	23	José María	Basanta	3	4	1984	M
10244	1	Mathew	Ryan	8	4	1992	M
12111	2	Ivan	Franjic	10	9	1987	M
5392	3	Jason	Davidson	29	6	1991	M
77068	6	Matthew	Spiranovic	27	6	1988	M
35837	7	Mathew	Leckie	4	2	1991	M
97422	8	Bailey	Wright	28	7	1992	M
81067	9	Adam	Taggart	2	6	1993	M
65381	10	Ben	Halloran	14	6	1992	M
84412	11	Tommy	Oar	10	12	1991	M
15064	12	Mitchell	Langerak	22	8	1988	M
52319	13	Oliver	Bozanic	8	1	1989	M
9100	14	James	Troisi	3	7	1988	M
77996	16	James	Holland	15	5	1989	M
93567	17	Matt	McKay	11	1	1983	M
95590	19	Ryan	McGowan	15	8	1989	M
33434	21	Massimo	Luongo	25	9	1992	M
60159	22	Alex	Wilkinson	13	8	1984	M
9658	1	Thibaut	Courtois	11	5	1992	M
70547	2	Toby	Alderweireld	2	3	1989	M
92866	3	Thomas	Vermaelen	14	11	1985	M
95269	4	Vincent	Kompany	10	4	1986	M
64049	5	Jan	Vertonghen	24	4	1987	M
53048	6	Axel	Witsel	12	1	1989	M
48955	7	Kevin	De Bruyne	28	6	1991	M
63363	8	Marouane	Fellaini	22	11	1987	M
72637	9	Romelu	Lukaku	13	5	1993	M
72011	10	Eden	Hazard	7	1	1991	M
25209	11	Kevin	Mirallas	5	10	1987	M
10313	12	Simon	Mignolet	6	3	1988	M
55762	13	Sammy	Bossut	11	8	1985	M
84852	14	Dries	Mertens	6	5	1987	M
3735	16	Steven	Defour	15	4	1988	M
77619	17	Divock	Origi	18	4	1995	M
35334	18	Nicolas	Lombaerts	20	3	1985	M
12533	19	Mousa	Dembélé	16	7	1987	M
15896	20	Adnan	Januzaj	5	2	1995	M
17974	21	Anthony	Vanden Borre	24	10	1987	M
69919	22	Nacer	Chadli	2	8	1989	M
33520	23	Laurent	Ciman	5	8	1985	M
80138	1	Asmir	Begović	20	6	1987	M
35118	2	Avdija	Vršajević	6	3	1986	M
66286	3	Ermin	Bičakčić	24	1	1990	M
68768	4	Emir	Spahić	18	8	1980	M
96934	5	Sead	Kolašinac	20	6	1993	M
52464	6	Ognjen	Vranješ	24	10	1989	M
74144	7	Muhamed	Bešić	10	9	1992	M
19478	8	Miralem	Pjanić	2	4	1990	M
43723	9	Vedad	Ibišević	6	8	1984	M
75995	10	Zvjezdan	Misimović	5	6	1982	M
31839	11	Edin	Džeko	17	3	1986	M
76271	12	Jasmin	Fejzić	15	5	1986	M
63525	13	Mensur	Mujdža	28	3	1984	M
85929	14	Tino-Sven	Sušić	13	2	1992	M
19073	15	Toni	Šunjić	15	12	1988	M
74278	16	Senad	Lulić	18	1	1986	M
64096	17	Senijad	Ibričić	26	9	1985	M
34727	18	Haris	Medunjanin	8	3	1985	M
55809	19	Edin	Višća	17	2	1990	M
3146	20	Izet	Hajrović	4	8	1991	M
15457	21	Anel	Hadžić	16	8	1989	M
78276	22	Asmir	Avdukić	13	5	1981	M
94434	23	Sejad	Salihović	8	10	1984	M
41422	1	not applicable	Jefferson	2	1	1983	M
87449	4	David	Luiz	22	4	1987	M
41758	5	not applicable	Fernandinho	4	5	1985	M
70650	6	not applicable	Marcelo	12	5	1988	M
86524	7	not applicable	Hulk	25	7	1986	M
54013	8	not applicable	Paulinho	25	7	1988	M
87008	10	not applicable	Neymar	5	2	1992	M
37239	11	not applicable	Oscar	9	9	1991	M
93619	13	not applicable	Dante	18	10	1983	M
47180	14	not applicable	Maxwell	27	8	1981	M
68649	15	not applicable	Henrique	14	10	1986	M
43410	17	Luiz	Gustavo	23	7	1987	M
2974	18	not applicable	Hernanes	29	5	1985	M
62621	19	not applicable	Willian	9	8	1988	M
50663	20	not applicable	Bernard	8	9	1992	M
37372	21	not applicable	Jô	20	3	1987	M
94095	22	not applicable	Victor	21	1	1983	M
36230	1	Loïc	Feudjou	14	4	1992	M
75443	4	Cédric	Djeugoué	28	8	1992	M
89372	5	Dany	Nounkeu	11	4	1986	M
65896	8	Benjamin	Moukandjo	12	11	1988	M
97635	12	Henri	Bedimo	4	6	1984	M
28726	16	Charles	Itandje	2	11	1982	M
81999	19	Fabrice	Olinga	12	5	1996	M
72737	20	Edgar	Salli	17	8	1992	M
5805	22	Allan	Nyom	10	5	1988	M
44581	23	Sammy	Ndjock	25	2	1990	M
9990	2	Eugenio	Mena	18	7	1988	M
75764	3	Miiko	Albornoz	30	11	1990	M
94202	5	Francisco	Silva	11	2	1986	M
89582	9	Mauricio	Pinilla	4	2	1984	M
36808	11	Eduardo	Vargas	20	11	1989	M
98429	12	Cristopher	Toselli	22	6	1988	M
3193	13	José Manuel	Rojas	3	6	1983	M
92626	16	Felipe	Gutiérrez	8	10	1990	M
65016	19	José Pablo	Fuenzalida	22	2	1985	M
22391	20	Charles	Aránguiz	17	4	1989	M
74494	21	Marcelo	Díaz	30	12	1986	M
47836	23	Johnny	Herrera	9	5	1981	M
94838	1	David	Ospina	31	8	1988	M
78745	2	Cristián	Zapata	30	9	1986	M
92771	3	Mario	Yepes	13	1	1976	M
1505	4	Santiago	Arias	13	1	1992	M
76077	5	Carlos	Carbonero	25	7	1990	M
66228	6	Carlos	Sánchez	6	2	1986	M
95402	7	Pablo	Armero	2	11	1986	M
76705	8	Abel	Aguilar	6	1	1985	M
77705	9	Teófilo	Gutiérrez	17	5	1985	M
89392	10	James	Rodríguez	12	7	1991	M
83216	11	Juan	Cuadrado	26	5	1988	M
27327	12	Camilo	Vargas	9	3	1989	M
66638	13	Fredy	Guarín	30	6	1986	M
99957	14	Víctor	Ibarbo	19	5	1990	M
1538	15	Alexander	Mejía	11	7	1988	M
86404	16	Éder	Álvarez Balanta	28	2	1993	M
12476	17	Carlos	Bacca	8	9	1986	M
61178	18	Juan Camilo	Zúñiga	14	12	1985	M
73564	19	Adrián	Ramos	22	1	1986	M
14499	20	Juan Fernando	Quintero	18	1	1993	M
1068	21	Jackson	Martínez	3	10	1986	M
77916	23	Carlos	Valdés	22	5	1985	M
81392	1	Keylor	Navas	15	12	1986	M
65320	2	Jhonny	Acosta	21	7	1983	M
4808	3	Giancarlo	González	8	2	1988	M
11767	5	Celso	Borges	27	5	1988	M
97912	6	Óscar	Duarte	3	6	1989	M
39550	8	David	Myrie	1	6	1988	M
70812	9	Joel	Campbell	26	6	1992	M
99590	10	Bryan	Ruiz	18	8	1985	M
74906	11	Michael	Barrantes	4	10	1983	M
24906	12	Waylon	Francis	20	9	1990	M
85499	13	Óscar	Granados	25	10	1985	M
21246	14	Randall	Brenes	13	8	1983	M
81779	15	Júnior	Díaz	12	9	1983	M
26483	16	Cristian	Gamboa	24	10	1989	M
24978	17	Yeltsin	Tejeda	17	3	1992	M
88896	18	Patrick	Pemberton	24	4	1982	M
88814	19	Roy	Miller	24	11	1984	M
16119	20	Diego	Calvo	25	3	1991	M
11307	21	Marco	Ureña	5	3	1990	M
71361	22	José Miguel	Cubero	14	2	1987	M
51981	23	Daniel	Cambronero	8	1	1986	M
65425	2	Šime	Vrsaljko	10	1	1992	M
52946	3	Danijel	Pranjić	2	12	1981	M
93884	4	Ivan	Perišić	2	2	1989	M
8916	5	Vedran	Ćorluka	5	2	1986	M
56297	6	Dejan	Lovren	5	7	1989	M
65979	7	Ivan	Rakitić	10	3	1988	M
2932	8	Ognjen	Vukojević	20	12	1983	M
65367	9	Nikica	Jelavić	27	8	1985	M
2919	12	Oliver	Zelenika	14	5	1993	M
33855	13	Gordon	Schildenfeld	18	3	1985	M
79215	14	Marcelo	Brozović	16	11	1992	M
77789	15	Milan	Badelj	25	2	1989	M
44463	16	Ante	Rebić	21	9	1993	M
25745	17	Mario	Mandžukić	21	5	1986	M
39138	19	not applicable	Sammir	23	4	1987	M
7670	20	Mateo	Kovačić	6	5	1994	M
91294	21	Domagoj	Vida	29	4	1989	M
15665	22	not applicable	Eduardo	25	2	1983	M
25428	23	Danijel	Subašić	27	10	1984	M
93941	1	Máximo	Banguera	16	12	1985	M
52676	3	Frickson	Erazo	5	5	1988	M
43280	4	Juan Carlos	Paredes	8	7	1987	M
73520	5	Renato	Ibarra	20	1	1991	M
33117	6	Christian	Noboa	9	4	1985	M
55935	7	Jefferson	Montero	1	9	1989	M
33089	9	Joao	Rojas	14	6	1989	M
79710	11	Felipe	Caicedo	5	9	1988	M
15123	12	Adrián	Bone	8	9	1988	M
75912	13	Enner	Valencia	4	11	1989	M
1933	14	Oswaldo	Minda	26	7	1983	M
65206	15	Michael	Arroyo	23	4	1987	M
73513	17	Jaime	Ayoví	21	2	1988	M
57715	18	Óscar	Bagüí	10	12	1982	M
31812	20	Fidel	Martínez	15	2	1990	M
29870	21	Gabriel	Achilier	24	3	1985	M
94877	22	Alexander	Domínguez	5	6	1987	M
13321	23	Carlos	Gruezo	19	4	1995	M
94649	3	Leighton	Baines	11	12	1984	M
56280	5	Gary	Cahill	19	12	1985	M
20585	6	Phil	Jagielka	17	8	1982	M
39063	7	Jack	Wilshere	1	1	1992	M
6678	9	Daniel	Sturridge	1	9	1989	M
50943	11	Danny	Welbeck	26	11	1990	M
87661	12	Chris	Smalling	22	11	1989	M
31138	13	Ben	Foster	3	4	1983	M
8169	14	Jordan	Henderson	17	6	1990	M
36639	15	Alex	Oxlade-Chamberlain	15	8	1993	M
6851	16	Phil	Jones	21	2	1992	M
70595	18	Rickie	Lambert	16	2	1982	M
21553	19	Raheem	Sterling	8	12	1994	M
22075	20	Adam	Lallana	10	5	1988	M
48443	21	Ross	Barkley	5	12	1993	M
7038	22	Fraser	Forster	17	3	1988	M
36400	23	Luke	Shaw	12	7	1995	M
43350	2	Mathieu	Debuchy	28	7	1985	M
42326	4	Raphaël	Varane	25	4	1993	M
71633	5	Mamadou	Sakho	13	2	1990	M
67867	6	Yohan	Cabaye	14	1	1986	M
79882	7	Rémy	Cabella	8	3	1990	M
89750	9	Olivier	Giroud	30	9	1986	M
35408	10	Karim	Benzema	19	12	1987	M
90908	11	Antoine	Griezmann	21	3	1991	M
98143	12	Rio	Mavuba	8	3	1984	M
8834	13	Eliaquim	Mangala	13	2	1991	M
4964	14	Blaise	Matuidi	9	4	1987	M
1560	16	Stéphane	Ruffier	27	9	1986	M
67129	17	Lucas	Digne	20	7	1993	M
7870	18	Moussa	Sissoko	16	8	1989	M
17509	19	Paul	Pogba	15	3	1993	M
21776	20	Loïc	Rémy	2	1	1987	M
91114	21	Laurent	Koscielny	10	9	1985	M
45182	22	Morgan	Schneiderlin	8	11	1989	M
97775	2	Kevin	Großkreutz	19	7	1988	M
36126	3	Matthias	Ginter	19	1	1994	M
54036	4	Benedikt	Höwedes	29	2	1988	M
81447	5	Mats	Hummels	16	12	1988	M
46979	9	André	Schürrle	6	11	1990	M
41334	12	Ron-Robert	Zieler	12	2	1989	M
21524	14	Julian	Draxler	20	9	1993	M
46023	15	Erik	Durm	12	5	1992	M
63673	19	Mario	Götze	3	6	1992	M
67414	21	Shkodran	Mustafi	17	4	1992	M
27707	22	Roman	Weidenfeller	6	8	1980	M
42177	23	Christoph	Kramer	19	2	1991	M
40630	1	Stephen	Adams	28	9	1989	M
4420	4	Daniel	Opare	18	10	1990	M
63370	6	Afriyie	Acquah	5	1	1992	M
48310	7	Christian	Atsu	10	1	1992	M
89904	8	Emmanuel	Agyemang-Badu	2	12	1990	M
84116	12	Adam Larsen	Kwarasey	12	12	1987	M
31765	13	Jordan	Ayew	11	9	1991	M
67189	14	Albert	Adomah	13	12	1987	M
20971	15	Rashid	Sumaila	18	12	1992	M
24689	16	Fatau	Dauda	6	4	1985	M
96497	17	Mohammed	Rabiu	31	12	1989	M
24388	18	Abdul Majeed	Waris	19	9	1991	M
6024	21	John	Boye	23	4	1987	M
31813	22	Mubarak	Wakaso	25	7	1990	M
5368	23	Harrison	Afful	24	6	1986	M
1064	1	Orestis	Karnezis	11	7	1985	M
96319	2	Giannis	Maniatis	12	10	1986	M
64835	3	Giorgos	Tzavellas	26	11	1987	M
23816	4	Kostas	Manolas	14	6	1991	M
91614	8	Panagiotis	Kone	26	7	1987	M
97050	9	Kostas	Mitroglou	12	3	1988	M
34712	12	Panagiotis	Glykos	3	6	1986	M
83726	13	Stefanos	Kapino	18	3	1994	M
68693	16	Lazaros	Christodoulopoulos	19	12	1986	M
64903	18	Giannis	Fetfatzidis	21	12	1990	M
59823	20	José	Holebas	27	6	1984	M
30845	22	Andreas	Samaris	13	6	1989	M
89305	23	Panagiotis	Tachtsidis	15	2	1991	M
19564	1	Luis	López	13	9	1993	M
74155	4	Juan Pablo	Montes	26	10	1985	M
33029	6	Juan Carlos	García	8	3	1988	M
5369	10	Mario	Martínez	30	7	1989	M
67290	11	Jerry	Bengtson	8	4	1987	M
93287	12	Edder	Delgado	20	11	1986	M
38682	13	Carlo	Costly	18	7	1982	M
86511	16	Rony	Martínez	16	10	1987	M
34878	17	Andy	Najar	16	3	1993	M
29674	19	Luis	Garrido	5	11	1990	M
30748	20	Jorge	Claros	8	1	1986	M
64512	21	Brayan	Beckeles	28	11	1985	M
36601	23	Marvin	Chávez	3	11	1983	M
37948	1	Rahman	Ahmadi	30	7	1980	M
82213	2	Khosro	Heydari	14	9	1983	M
75785	3	Ehsan	Hajsafi	25	2	1990	M
19512	4	Jalal	Hosseini	3	2	1982	M
5990	8	Reza	Haghighi	1	2	1989	M
98775	9	Alireza	Jahanbakhsh	11	8	1993	M
53957	10	Karim	Ansarifard	3	4	1990	M
70046	11	Ghasem	Haddadifar	12	7	1983	M
13053	12	Alireza	Haghighi	2	5	1988	M
41304	13	Hossein	Mahini	16	9	1986	M
23272	15	Pejman	Montazeri	6	9	1983	M
85324	16	Reza	Ghoochannejhad	20	9	1987	M
82861	17	Ahmad	Alenemeh	10	10	1982	M
15489	18	Bakhtiar	Rahmani	23	9	1991	M
82054	19	Hashem	Beikzadeh	22	1	1984	M
7353	20	Steven	Beitashour	1	2	1987	M
84406	21	Ashkan	Dejagah	5	7	1986	M
32139	22	Daniel	Davari	6	1	1988	M
94249	23	Mehrdad	Pooladi	26	2	1987	M
67615	2	Mattia	De Sciglio	20	10	1992	M
99163	4	Matteo	Darmian	2	12	1989	M
32717	5	Thiago	Motta	28	8	1982	M
35850	6	Antonio	Candreva	28	2	1987	M
75462	7	Ignazio	Abate	12	11	1986	M
16785	9	Mario	Balotelli	12	8	1990	M
4221	10	Antonio	Cassano	12	7	1982	M
39774	11	Alessio	Cerci	23	7	1987	M
60016	12	Salvatore	Sirigu	12	1	1987	M
60769	13	Mattia	Perin	10	11	1992	M
1292	14	Alberto	Aquilani	7	7	1984	M
1078	17	Ciro	Immobile	20	2	1990	M
61270	18	Marco	Parolo	25	1	1985	M
73649	20	Gabriel	Paletta	15	2	1986	M
25985	22	Lorenzo	Insigne	4	6	1991	M
43029	23	Marco	Verratti	5	11	1992	M
65804	2	Ousmane	Viera	21	12	1986	M
23169	6	Mathis	Bolly	14	11	1990	M
42905	7	Jean-Daniel	Akpa Akpro	11	10	1992	M
84532	12	Wilfried	Bony	10	12	1988	M
20974	13	Didier	Ya Konan	22	5	1984	M
7076	14	Ismaël	Diomandé	28	8	1992	M
10731	15	Max	Gradel	30	11	1987	M
25845	16	Sylvain	Gbohouo	29	10	1988	M
43440	17	Serge	Aurier	24	12	1992	M
75959	18	Constant	Djakpa	17	10	1986	M
54100	20	Serey	Dié	7	11	1984	M
33115	21	Giovanni	Sio	31	3	1989	M
89713	23	Sayouba	Mandé	15	6	1993	M
62769	3	Gōtoku	Sakai	14	3	1991	M
27263	6	Masato	Morishige	21	5	1987	M
42018	8	Hiroshi	Kiyotake	12	11	1989	M
36964	10	Shinji	Kagawa	17	3	1989	M
75667	11	Yoichiro	Kakitani	3	1	1990	M
28762	12	Shusaku	Nishikawa	18	6	1986	M
70237	14	Toshihiro	Aoyama	22	2	1986	M
41027	16	Hotaru	Yamaguchi	6	10	1990	M
23371	18	Yuya	Osako	18	5	1990	M
81377	19	Masahiko	Inoha	28	8	1983	M
53076	20	Manabu	Saitō	4	4	1990	M
56398	21	Hiroki	Sakai	12	4	1990	M
89321	22	Maya	Yoshida	24	8	1988	M
66906	23	Shūichi	Gonda	3	3	1989	M
3287	5	Diego	Reyes	19	9	1992	M
42911	6	Héctor	Herrera	19	4	1990	M
10063	7	Miguel	Layún	25	6	1988	M
36687	8	Marco	Fabián	21	7	1989	M
57865	9	Raúl	Jiménez	5	5	1991	M
75041	11	Alan	Pulido	8	3	1991	M
94928	12	Alfredo	Talavera	18	9	1982	M
29705	16	Miguel Ángel	Ponce	12	4	1989	M
11638	17	Isaác	Brizuela	28	8	1990	M
83642	19	Oribe	Peralta	12	1	1984	M
77419	20	Javier	Aquino	11	2	1990	M
77489	21	Carlos	Peña	29	3	1990	M
22756	23	José Juan	Vázquez	14	3	1988	M
68395	1	Jasper	Cillessen	22	4	1989	M
21798	2	Ron	Vlaar	16	2	1985	M
70280	3	Stefan	de Vrij	5	2	1992	M
69329	4	Bruno	Martins Indi	8	2	1992	M
39861	5	Daley	Blind	9	3	1990	M
21790	7	Daryl	Janmaat	22	7	1989	M
93667	8	Jonathan	de Guzmán	13	9	1987	M
26380	12	Paul	Verhaegh	1	9	1983	M
91472	13	Joël	Veltman	15	1	1992	M
70414	14	Terence	Kongolo	14	2	1994	M
27533	16	Jordy	Clasie	27	6	1991	M
62029	17	Jeremain	Lens	24	11	1987	M
20877	18	Leroy	Fer	5	1	1990	M
85698	20	Georginio	Wijnaldum	11	11	1990	M
27540	21	Memphis	Depay	13	2	1994	M
42745	23	Tim	Krul	3	4	1988	M
28119	3	Ejike	Uzoenyi	23	3	1988	M
94823	4	Reuben	Gabriel	25	9	1990	M
22192	5	Efe	Ambrose	18	10	1988	M
40374	6	Azubuike	Egwuekwe	16	7	1989	M
19591	7	Ahmed	Musa	14	10	1992	M
95567	9	Emmanuel	Emenike	10	5	1987	M
1164	10	John Obi	Mikel	22	4	1987	M
26900	11	Victor	Moses	12	12	1990	M
37901	12	Kunle	Odunlami	30	4	1991	M
79048	13	Juwon	Oshaniwa	14	9	1990	M
14952	14	Godfrey	Oboabona	16	8	1990	M
78347	15	Ramon	Azeez	12	12	1992	M
94774	17	Ogenyi	Onazi	25	12	1992	M
66596	18	Michael	Babatunde	24	12	1992	M
97867	19	Uche	Nwofor	17	9	1991	M
15097	20	Michael	Uchebo	2	2	1990	M
53035	21	Chigozie	Agbim	28	11	1984	M
98806	22	Kenneth	Omeruo	17	10	1993	M
3886	23	Shola	Ameobi	12	10	1981	M
44689	6	William	Carvalho	7	4	1992	M
89743	8	João	Moutinho	8	9	1986	M
23990	10	not applicable	Vieirinha	24	1	1986	M
20926	11	not applicable	Eder	22	12	1987	M
72028	12	Rui	Patrício	15	2	1988	M
5377	14	Luís	Neto	26	5	1988	M
82734	15	Rafa	Silva	17	5	1993	M
78296	17	not applicable	Nani	17	11	1986	M
25600	18	Silvestre	Varela	2	2	1985	M
75772	19	André	Almeida	10	9	1990	M
17971	21	João	Pereira	25	2	1984	M
95453	1	Igor	Akinfeev	8	4	1986	M
21554	2	Aleksei	Kozlov	16	11	1986	M
83934	3	Georgi	Shchennikov	27	4	1991	M
79763	4	Sergei	Ignashevich	14	7	1979	M
36787	5	Andrei	Semyonov	24	3	1989	M
12197	6	Maksim	Kanunnikov	14	7	1991	M
76640	7	Igor	Denisov	17	5	1984	M
30808	8	Denis	Glushakov	27	1	1987	M
67113	9	Aleksandr	Kokorin	19	3	1991	M
69896	10	Alan	Dzagoev	17	6	1990	M
3044	12	Yuri	Lodygin	26	5	1990	M
11462	13	Vladimir	Granat	22	5	1987	M
31094	14	Vasili	Berezutski	20	6	1982	M
1665	15	Pavel	Mogilevets	25	1	1993	M
85559	16	Sergey	Ryzhikov	19	9	1980	M
27894	17	Oleg	Shatov	29	7	1990	M
51786	18	Yuri	Zhirkov	20	8	1983	M
6356	19	Aleksandr	Samedov	19	7	1984	M
8275	20	Viktor	Fayzulin	22	4	1986	M
73380	21	Aleksei	Ionov	18	2	1989	M
98872	22	Andrey	Yeshchenko	9	2	1984	M
63644	23	Dmitri	Kombarov	22	1	1987	M
19142	2	Chang-soo	Kim	12	9	1985	M
13271	3	Suk-young	Yun	13	2	1990	M
28296	4	Tae-hwi	Kwak	8	7	1981	M
7259	5	Young-gwon	Kim	27	2	1990	M
9632	6	Seok-ho	Hwang	27	6	1989	M
3869	8	Dae-sung	Ha	2	3	1985	M
77335	9	Heung-min	Son	8	7	1992	M
71308	11	Keun-ho	Lee	11	4	1985	M
64718	12	Yong	Lee	24	12	1986	M
47440	13	Ja-cheol	Koo	27	2	1989	M
29447	14	Kook-young	Han	19	4	1990	M
71373	15	Jong-woo	Park	10	3	1989	M
15736	18	Shin-wook	Kim	14	4	1988	M
3922	19	Dong-won	Ji	28	5	1991	M
55453	20	Jeong-ho	Hong	12	8	1989	M
42523	21	Seung-gyu	Kim	30	9	1990	M
16489	22	Joo-ho	Park	16	1	1987	M
18963	23	Bum-young	Lee	2	4	1989	M
35157	5	not applicable	Juanfran	9	1	1985	M
52217	12	David	de Gea	7	11	1990	M
37294	17	not applicable	Koke	8	1	1992	M
1416	18	Jordi	Alba	21	3	1989	M
2231	19	Diego	Costa	7	10	1988	M
98074	20	Santi	Cazorla	13	12	1984	M
60716	22	César	Azpilicueta	28	8	1989	M
95507	6	Michael	Lang	8	2	1991	M
7180	9	Haris	Seferovic	22	2	1992	M
77224	10	Granit	Xhaka	27	9	1992	M
63312	12	Yann	Sommer	17	12	1988	M
43367	13	Ricardo	Rodríguez	25	8	1992	M
875	14	Valentin	Stocker	12	4	1989	M
36686	17	Mario	Gavranović	24	11	1989	M
51579	18	Admir	Mehmedi	16	3	1991	M
7453	19	Josip	Drmić	8	8	1992	M
90361	21	Roman	Bürki	14	11	1990	M
25131	22	Fabian	Schär	20	12	1991	M
95273	2	DeAndre	Yedlin	9	7	1993	M
20244	3	Omar	Gonzalez	11	10	1988	M
95009	5	Matt	Besler	11	2	1987	M
41262	6	John	Brooks	28	1	1993	M
1169	9	Aron	Jóhannsson	10	11	1990	M
24300	10	Mix	Diskerud	2	10	1990	M
9053	11	Alejandro	Bedoya	29	4	1987	M
10072	13	Jermaine	Jones	3	11	1981	M
41052	14	Brad	Davis	8	11	1981	M
45750	15	Kyle	Beckerman	23	4	1982	M
91438	16	Julian	Green	6	6	1995	M
78024	18	Chris	Wondolowski	28	1	1983	M
51653	19	Graham	Zusi	18	8	1986	M
31173	20	Geoff	Cameron	11	7	1985	M
98378	21	Timothy	Chandler	29	3	1990	M
78113	22	Nick	Rimando	17	6	1979	M
71933	23	Fabian	Johnson	11	12	1987	M
14180	7	Cristian	Rodríguez	30	9	1985	M
94155	8	Abel	Hernández	8	8	1990	M
25776	11	Cristhian	Stuani	12	10	1986	M
18230	12	Rodrigo	Muñoz	22	1	1982	M
65659	13	José	Giménez	20	1	1995	M
79723	18	Gastón	Ramírez	2	12	1990	M
20051	19	Sebastián	Coates	7	10	1990	M
21702	20	Álvaro	González	29	10	1984	M
76518	2	Larissa	Crummer	10	1	1996	F
26438	3	Ashleigh	Sykes	15	12	1991	F
28164	7	Steph	Catley	26	1	1994	F
27559	14	Alanna	Kennedy	21	1	1995	F
29422	15	Teresa	Polias	16	5	1990	F
39150	16	Hayley	Raso	5	9	1994	F
81599	19	Katrina	Gorry	13	8	1992	F
11976	21	Mackenzie	Arnold	25	2	1994	F
95346	22	Nicola	Bolger	3	3	1993	F
83314	23	Michelle	Heyman	4	7	1988	F
69429	1	not applicable	Luciana	24	7	1987	F
83758	3	not applicable	Mônica	21	4	1987	F
23163	4	not applicable	Rafinha	18	8	1988	F
53274	5	not applicable	Andressinha	1	5	1995	F
60585	6	not applicable	Tamires	10	10	1987	F
62964	8	not applicable	Thaisa	17	12	1988	F
91993	9	Andressa	Alves	10	11	1992	F
35462	13	not applicable	Poliana	6	2	1991	F
96310	14	not applicable	Géssica	19	3	1991	F
18602	15	not applicable	Tayla	9	5	1992	F
4136	16	not applicable	Rafaelle	18	6	1991	F
11773	18	not applicable	Raquel	21	3	1991	F
38186	21	Gabi	Zanotti	28	2	1985	F
53133	22	not applicable	Darlene	11	1	1990	F
3553	23	Letícia	Izidoro	13	8	1994	F
39837	1	Annette	Ngo Ndom	2	6	1985	F
22573	2	Christine	Manie	4	5	1984	F
69986	3	Ajara	Nchout	12	1	1993	F
30264	4	Yvonne	Leuko	20	11	1991	F
12298	5	Augustine	Ejangue	19	1	1989	F
27272	6	Francine	Zouga	9	11	1987	F
24905	7	Gabrielle	Onguéné	25	2	1989	F
1302	8	Raissa	Feudjio	29	10	1995	F
43002	9	Madeleine	Ngono Mani	16	10	1983	F
95451	10	Jeannette	Yango	12	6	1993	F
59141	11	Aurelle	Awona	2	2	1993	F
36793	12	Claudine	Meffometou	1	7	1990	F
35045	13	Cathy	Bou Ndjouh	7	11	1987	F
58512	14	Ninon	Abena	5	9	1994	F
80017	15	Ysis	Sonkeng	20	9	1989	F
91402	16	Thècle	Mbororo	24	9	1989	F
18928	17	Gaëlle	Enganamouit	9	6	1992	F
62839	18	Henriette	Akaba	7	6	1992	F
45630	19	Agathe	Ngani	26	5	1992	F
83450	20	Genevieve	Ngo Mbeleck	10	3	1993	F
36719	21	Rose	Bella	5	5	1994	F
30621	22	Wanki	Awachwi	6	1	1994	F
49063	23	Flore	Enyegue	9	7	1991	F
60142	3	Kadeisha	Buchanan	5	11	1995	F
31118	9	Josée	Bélanger	14	5	1986	F
68495	10	Lauren	Sesselmann	14	8	1983	F
97105	15	Allysha	Chapman	25	1	1989	F
3895	17	Jessie	Fleming	11	3	1998	F
43516	18	Selenia	Iacchelli	5	6	1986	F
16470	19	Adriana	Leon	2	10	1992	F
67881	22	Ashley	Lawrence	11	6	1995	F
89223	1	Yue	Zhang	30	9	1990	F
97958	2	Shanshan	Liu	16	3	1992	F
66822	3	Fengyue	Pang	19	1	1989	F
27970	4	Jiayue	Li	8	6	1990	F
66124	5	Haiyan	Wu	26	2	1993	F
14918	7	Yanlu	Xu	16	9	1991	F
13961	8	Jun	Ma	6	3	1989	F
40014	9	Shanshan	Wang	27	1	1990	F
33435	10	Ying	Li	7	1	1993	F
26515	11	Shuang	Wang	23	1	1995	F
50707	12	Fei	Wang	22	3	1990	F
54562	13	Jiali	Tang	16	3	1995	F
17273	14	Rong	Zhao	2	8	1991	F
54615	15	Jiahui	Lei	22	9	1995	F
89089	16	Jiahui	Lou	26	5	1991	F
12565	17	Yasha	Gu	28	11	1990	F
20162	18	Peng	Han	20	12	1989	F
99247	19	Ruyin	Tan	17	7	1994	F
98819	20	Rui	Zhang	17	1	1989	F
59654	21	Lisi	Wang	28	11	1991	F
58856	22	Lina	Zhao	18	9	1991	F
89921	23	Guixin	Ren	19	12	1988	F
19392	1	Stefany	Castaño	11	1	1994	F
19996	2	Carolina	Arbeláez	8	3	1995	F
72076	5	Lina	Granados	19	5	1994	F
28594	8	Mildrey	Pineda	1	10	1989	F
28701	13	Ángela	Clavijo	1	9	1993	F
41243	17	Carolina	Arias	2	9	1990	F
29954	18	Yisela	Cuesta	27	9	1991	F
34188	19	Leicy	Santos	16	5	1996	F
65458	20	Laura	Cosme	5	3	1992	F
17370	21	Isabella	Echeverri	16	6	1994	F
9774	22	Catalina	Pérez	8	11	1994	F
1092	23	Manuela	González	29	8	1995	F
22795	1	Dinnia	Díaz	14	1	1988	F
87484	2	Gabriela	Guillén	1	3	1992	F
19744	3	Emilie	Valenciano	15	2	1997	F
74292	4	Mariana	Benavides	26	12	1994	F
49906	5	Diana	Sáenz	15	4	1989	F
1384	6	Carol	Sánchez	16	4	1986	F
83648	7	Melissa	Herrera	10	10	1996	F
10868	8	Daniela	Cruz	8	3	1991	F
54445	9	Carolina	Venegas	28	9	1991	F
90891	10	Shirley	Cruz	28	8	1985	F
8309	11	Raquel	Rodríguez	28	10	1993	F
99437	12	Lixy	Rodríguez	4	11	1990	F
33626	13	Noelia	Bermúdez	20	9	1994	F
86294	14	María	Barrantes	12	4	1989	F
92744	15	Cristín	Granados	19	8	1989	F
32687	16	Katherine	Alvarado	11	4	1991	F
87850	17	Karla	Villalobos	16	7	1986	F
8652	18	Yirlania	Arroyo	28	5	1986	F
13574	19	Fabiola	Sánchez	9	4	1993	F
52241	20	Wendy	Acosta	19	12	1989	F
20075	21	Adriana	Venegas	12	6	1989	F
86097	22	María	Coto	2	3	1998	F
97070	23	Gloriana	Villalobos	20	8	1999	F
62261	1	Shirley	Berruz	6	1	1991	F
24375	2	Katherine	Ortiz	16	2	1991	F
72265	3	Lorena	Aguilar	6	7	1985	F
33203	4	Merly	Zambrano	7	12	1981	F
63919	5	Mayra	Olvera	22	8	1992	F
18236	6	Angie	Ponce	14	7	1996	F
86830	7	Ingrid	Rodríguez	24	11	1991	F
28880	8	Erika	Vásquez	4	8	1992	F
86541	9	Giannina	Lattanzio	19	5	1993	F
54239	10	Ámbar	Torres	21	12	1994	F
32204	11	Mónica	Quinteros	5	7	1988	F
70975	12	Irene	Tobar	5	5	1989	F
46613	13	Madelin	Riera	7	8	1989	F
4586	14	Carina	Caicedo	23	7	1987	F
78692	15	Valeria	Palacios	16	2	1991	F
16218	16	Ligia	Moreira	19	3	1992	F
74308	17	Alexandra	Salvador	11	8	1995	F
17523	18	Adriana	Barré	4	4	1995	F
62444	19	Kerlly	Real	7	11	1998	F
86883	20	Denise	Pesántes	14	1	1988	F
63107	21	Mabel	Velarde	4	12	1988	F
25118	22	Andrea	Vera	10	4	1993	F
82637	23	Mariela	Jácome	6	3	1996	F
17951	7	Jordan	Nobbs	8	12	1992	F
76594	11	Jade	Moore	22	10	1990	F
23779	12	Lucy	Bronze	28	10	1991	F
38788	14	Alex	Greenwood	7	9	1993	F
15279	17	Jo	Potter	13	11	1984	F
96810	18	Toni	Duggan	25	7	1991	F
57382	19	Jodie	Taylor	17	5	1986	F
61922	22	Fran	Kirby	29	6	1993	F
86196	5	Sabrina	Delannoy	18	5	1986	F
64050	6	Amandine	Henry	28	9	1989	F
15484	7	Kenza	Dali	31	7	1991	F
29761	8	Jessica	Houara	29	9	1987	F
13090	11	Claire	Lavogez	18	6	1994	F
68484	13	Kadidiatou	Diani	1	4	1995	F
12977	16	Sarah	Bouhaddi	17	10	1986	F
75169	19	Griedge	Mbock Bathy	26	2	1995	F
15353	20	Annaïg	Butel	15	2	1992	F
96957	21	Méline	Gérard	30	5	1990	F
14916	22	Amel	Majri	25	1	1993	F
8612	23	Kheira	Hamraoui	13	1	1990	F
32680	4	Leonie	Maier	29	9	1992	F
32037	8	Pauline	Bremer	10	4	1996	F
27576	9	Lena	Lotzen	11	9	1993	F
84273	10	Dzsenifer	Marozsán	18	4	1992	F
83981	15	Jennifer	Cramer	24	2	1993	F
17418	16	Melanie	Leupolz	14	4	1994	F
23193	17	Josephine	Henning	8	9	1989	F
27184	19	Lena	Petermann	5	2	1994	F
25439	21	Laura	Benkarth	14	10	1992	F
35449	22	Tabea	Kemme	14	12	1991	F
29896	23	Sara	Däbritz	15	2	1995	F
14561	1	Lydie	Saki	22	12	1984	F
52652	2	Fatou	Coulibaly	13	2	1987	F
87303	3	Djelika	Coulibaly	22	2	1984	F
24039	4	Nina	Kpaho	30	12	1996	F
29325	5	Mariam	Diakité	11	4	1995	F
97929	6	Rita	Akaffou	5	12	1986	F
26592	7	Nadege	Essoh	5	5	1990	F
77510	8	Ines	Nrehy	1	10	1993	F
64825	9	Sandrine	Niamien	30	8	1994	F
26065	10	Ange	N'Guessan	18	11	1990	F
39616	11	Rebecca	Elloh	25	12	1994	F
97884	12	Ida	Guehai	15	7	1994	F
28307	13	Fernande	Tchetche	20	6	1988	F
6222	14	Josée	Nahi	29	5	1989	F
83359	15	Christine	Lohoues	18	10	1992	F
54977	16	Dominique	Thiamale	20	5	1982	F
12080	17	Nadège	Cissé	4	4	1997	F
43472	18	Binta	Diakité	7	5	1988	F
95918	19	Jessica	Aby	16	6	1998	F
69358	20	Aminata	Haidara	13	5	1997	F
75197	21	Sophie	Aguie	31	12	1996	F
85546	22	Raymonde	Kacou	7	1	1987	F
6228	23	Cynthia	Djohore	16	12	1987	F
34571	15	Yuika	Sugasawa	5	10	1990	F
66148	19	Saori	Ariyoshi	1	11	1987	F
58036	20	Yuri	Kawamura	17	5	1989	F
93312	21	Erina	Yamane	20	12	1990	F
10268	22	Asano	Nagasato	24	1	1989	F
38281	23	Kana	Kitahara	17	12	1988	F
83	3	Christina	Murillo	28	1	1993	F
91979	5	Valeria	Miranda	18	8	1992	F
13965	6	Jenny	Ruiz	9	8	1983	F
61340	13	Greta	Espinoza	5	6	1995	F
37293	14	Arianna	Romero	29	7	1992	F
59103	15	Bianca	Sierra	25	6	1992	F
61373	18	Amanda	Pérez	31	7	1994	F
33628	19	Renae	Cuéllar	24	6	1990	F
34363	20	María	Sánchez	20	2	1996	F
50449	21	Anisa	Guajardo	10	3	1991	F
33442	22	Fabiola	Ibarra	2	2	1994	F
64086	23	Emily	Alvarado	9	6	1998	F
76328	1	Loes	Geurts	12	1	1986	F
3702	2	Desiree	van Lunteren	30	12	1992	F
13594	3	Stefanie	van der Gragt	16	8	1992	F
97745	4	Mandy	van den Berg	26	8	1990	F
36297	5	Petra	Hogewoning	26	3	1986	F
53833	6	Anouk	Dekker	15	11	1986	F
83474	7	Manon	Melis	31	8	1986	F
12051	8	Sherida	Spitse	29	5	1990	F
69967	9	Vivianne	Miedema	15	7	1996	F
70845	10	Daniëlle	van de Donk	5	8	1991	F
336	11	Lieke	Martens	16	12	1992	F
73591	12	Dyanne	Bito	10	8	1981	F
94893	13	Dominique	Bloodworth	17	1	1995	F
52192	14	Anouk	Hoogendijk	6	5	1985	F
63236	15	Merel	van Dongen	11	2	1993	F
47320	16	Sari	van Veenendaal	3	4	1990	F
4527	17	Tessel	Middag	23	12	1992	F
73711	18	Maran	van Erp	3	12	1990	F
98141	19	Kirsten	van de Ven	11	5	1985	F
52476	20	Jill	Roord	22	4	1997	F
46894	21	Vanity	Lewerissa	1	4	1991	F
30342	22	Shanice	van de Sanden	2	10	1992	F
71273	23	Angela	Christ	6	3	1989	F
44826	6	Rebekah	Stott	17	6	1993	F
26444	8	Jasmine	Pereira	20	7	1996	F
5868	15	Meikayla	Moore	4	6	1996	F
33611	18	CJ	Bott	22	4	1995	F
58749	19	Evie	Millynn	23	11	1994	F
94989	20	Daisy	Cleverley	30	4	1997	F
14580	21	Rebecca	Rolls	22	8	1975	F
34428	23	Cushla	Lichtwark	29	11	1980	F
54462	2	Blessing	Edoho	5	9	1992	F
33779	7	Esther	Sunday	13	3	1992	F
59598	8	Asisat	Oshoala	9	10	1994	F
88673	10	Courtney	Dike	3	2	1995	F
84505	11	Ini-Abasi	Umotong	15	5	1994	F
43499	12	Halimatu	Ayinde	16	5	1995	F
22604	13	Ngozi	Okobi-Okeoghene	14	12	1993	F
62439	14	Evelyn	Nwabuoku	14	11	1985	F
92381	15	Ugo	Njoku	27	11	1994	F
49049	16	Ibubeleye	Whyte	9	1	1992	F
45550	18	Loveth	Ayila	6	9	1994	F
9158	19	Martina	Ohadugha	5	5	1991	F
90856	20	Cecilia	Nku	26	10	1992	F
95601	21	Christy	Ohiaeriaku	13	12	1996	F
17938	22	Sarah	Nnodim	25	12	1995	F
9501	23	Ngozi	Ebere	5	8	1991	F
85744	2	Maria	Thorisdottir	5	6	1993	F
67898	5	Lisa-Marie Karlseng	Utland	19	9	1992	F
71462	10	Anja	Sønstevold	21	6	1992	F
79740	13	Ingrid	Moe Wold	29	1	1990	F
9339	14	Ingrid	Schjelderup	21	12	1987	F
40880	15	Marit	Sandvei	21	5	1987	F
75265	18	Melissa	Bjånesøy	18	4	1992	F
20831	21	Ada	Hegerberg	10	7	1995	F
89817	22	Hege	Hansen	24	10	1990	F
32235	23	Cecilie	Fiskerstrand	20	3	1996	F
64083	1	Min-kyung	Jun	16	1	1985	F
70687	2	Eun-mi	Lee	18	8	1988	F
96637	3	Seon-joo	Lim	27	11	1990	F
77758	4	Seo-yeon	Shim	15	4	1989	F
11539	5	Do-yeon	Kim	7	12	1988	F
73479	6	Bo-ram	Hwang	6	10	1987	F
83266	7	Ga-eul	Jeon	14	9	1988	F
35864	8	So-hyun	Cho	24	6	1988	F
8264	10	So-yun	Ji	21	2	1991	F
49393	11	Seol-bin	Jung	6	1	1990	F
57457	12	Young-a	Yoo	15	4	1988	F
80717	13	Hah-nul	Kwon	7	3	1988	F
68960	14	Su-ran	Song	7	9	1990	F
61973	15	Hee-young	Park	21	3	1991	F
46735	16	Yu-mi	Kang	5	10	1991	F
43720	17	Hye-yeong	Kim	26	2	1995	F
78430	19	Soo-yun	Kim	30	8	1989	F
58271	20	Hye-ri	Kim	25	6	1990	F
46793	21	Young-geul	Yoon	28	10	1987	F
39704	22	So-dam	Lee	12	10	1994	F
97215	23	Geum-min	Lee	7	4	1994	F
20973	1	Ainhoa	Tirapu	4	9	1984	F
70737	2	Celia	Jiménez	20	6	1995	F
47865	3	Leire	Landa	19	12	1986	F
41819	4	Melanie	Serrano	12	10	1989	F
62127	5	Ruth	García	26	4	1987	F
65568	6	Virginia	Torrecilla	4	9	1994	F
55768	7	Natalia	Pablos	15	10	1985	F
43292	8	Sonia	Bermúdez	18	11	1984	F
37281	9	Verónica	Boquete	9	4	1987	F
90837	10	Jennifer	Hermoso	9	5	1990	F
36051	11	Priscila	Borja	28	4	1985	F
84365	12	Marta	Corredera	8	8	1991	F
92234	13	Lola	Gallardo	10	6	1993	F
10289	14	Vicky	Losada	5	3	1991	F
16259	15	Silvia	Meseguer	12	3	1989	F
5213	16	Ivana	Andrés	13	7	1994	F
57894	17	Elisabeth	Ibarra	29	6	1981	F
62805	18	Marta	Torrejón	27	2	1990	F
60401	19	Erika	Vázquez	16	2	1983	F
79226	20	Irene	Paredes	4	7	1991	F
68406	21	Alexia	Putellas	4	2	1994	F
19347	22	Amanda	Sampedro	26	6	1993	F
1567	23	Sandra	Paños	4	11	1992	F
62801	4	Emma	Berglund	19	12	1988	F
90086	9	Kosovare	Asllani	29	7	1989	F
3180	11	Jenny	Hjohlman	13	2	1990	F
8987	12	Hilda	Carlén	13	8	1991	F
88969	13	Malin	Diaz	3	1	1994	F
2921	14	Amanda	Ilestedt	17	1	1993	F
16575	18	Jessica	Samuelsson	30	1	1993	F
1096	19	Emma	Lundh	26	6	1989	F
32524	20	Emilia	Appelqvist	11	2	1990	F
99096	21	Carola	Söberg	29	7	1982	F
10653	22	Olivia	Schough	11	3	1991	F
76903	23	Elin	Rubensson	11	5	1993	F
47686	1	Gaëlle	Thalmann	18	1	1986	F
16182	2	Nicole	Remund	31	12	1989	F
6149	3	Sandra	Betschart	30	3	1989	F
94332	4	Rachel	Rinast	2	6	1991	F
47527	5	Noelle	Maritz	23	12	1995	F
84754	6	Selina	Kuster	8	8	1991	F
15441	7	Martina	Moser	9	4	1986	F
63976	8	Cinzia	Zehnder	4	8	1997	F
97288	9	Lia	Wälti	19	4	1993	F
61487	10	Ramona	Bachmann	25	12	1990	F
53368	11	Lara	Dickenmann	27	11	1985	F
6268	12	Stenia	Michel	23	10	1987	F
96874	13	Ana-Maria	Crnogorčević	3	10	1990	F
86179	14	Rahel	Kiwic	5	1	1991	F
7698	15	Caroline	Abbé	13	1	1988	F
28291	16	Fabienne	Humm	20	12	1986	F
38433	17	Florijana	Ismaili	1	1	1995	F
43224	18	Vanessa	Bürki	1	4	1986	F
25824	19	Eseosa	Aigbogun	23	5	1993	F
84810	20	Daniela	Schwarz	9	9	1985	F
96558	21	Jennifer	Oehrli	13	1	1989	F
26247	22	Vanessa	Bernauer	23	3	1988	F
67107	23	Barla	Deplazes	14	11	1995	F
87745	1	Boonsing	Waraporn	16	2	1990	F
27270	2	Changplook	Darut	3	2	1988	F
5007	3	Chinwong	Natthakarn	15	3	1992	F
8487	4	Sritala	Duangnapa	4	2	1986	F
50085	5	Phancha	Ainon	26	1	1992	F
2347	6	Khueanpet	Pikul	20	9	1988	F
53921	7	Intamee	Silawan	22	1	1994	F
75728	8	Seesraum	Naphat	11	5	1987	F
26203	9	Phetwiset	Warunee	13	12	1990	F
61491	10	Srangthaisong	Sunisa	6	5	1988	F
67549	11	Rukpinij	Alisa	2	2	1995	F
14339	12	Thongsombut	Rattikan	7	7	1991	F
42972	13	Srimanee	Orathai	12	6	1988	F
34796	14	Chawong	Thanatta	19	6	1989	F
92650	15	Duanjanthuek	Nattaya	9	6	1991	F
65800	16	Saengchan	Khwanrudi	16	5	1991	F
23964	17	Maijarern	Anootsara	14	2	1986	F
62941	18	Sengyong	Yada	10	9	1993	F
69603	19	Dangda	Taneekarn	15	12	1992	F
50304	20	Boothduang	Wilaiporn	25	6	1987	F
88523	21	Sungngoen	Kanjana	21	9	1986	F
77946	22	Chor Charoenying	Sukanya	24	11	1987	F
78623	23	Romyen	Nisa	18	1	1990	F
52843	2	Sydney	Leroux	7	5	1990	F
39779	6	Whitney	Engen	28	11	1987	F
96028	14	Morgan	Brian	26	2	1993	F
32811	18	Ashlyn	Harris	19	10	1985	F
65433	19	Julie	Ertz	6	4	1992	F
12946	21	Alyssa	Naeher	20	4	1988	F
74823	22	Meghan	Klingenberg	2	8	1988	F
79931	23	Christen	Press	29	12	1988	F
18444	1	Nahuel	Guzmán	10	2	1986	M
32508	2	Gabriel	Mercado	18	3	1987	M
35173	3	Nicolás	Tagliafico	31	8	1992	M
64424	4	Cristian	Ansaldi	20	9	1986	M
981	6	Federico	Fazio	17	3	1987	M
66433	7	Éver	Banega	29	6	1988	M
73712	8	Marcos	Acuña	28	10	1991	M
39788	12	Franco	Armani	16	10	1986	M
95278	13	Maximiliano	Meza	15	12	1992	M
22992	18	Eduardo	Salvio	13	7	1990	M
16352	20	Giovani	Lo Celso	9	4	1996	M
28151	21	Paulo	Dybala	15	11	1993	M
85116	22	Cristian	Pavón	21	1	1996	M
17853	23	Willy	Caballero	28	9	1981	M
59727	2	Miloš	Degenek	28	4	1994	M
61767	3	James	Meredith	5	4	1988	M
58540	6	Matthew	Jurman	8	12	1989	M
61256	9	Tomi	Juric	22	7	1991	M
45528	10	Robbie	Kruse	5	10	1988	M
91329	11	Andrew	Nabbout	17	12	1992	M
84536	12	Brad	Jones	19	3	1982	M
95847	13	Aaron	Mooy	15	9	1990	M
20087	14	Jamie	Maclaren	29	7	1993	M
51118	16	Aziz	Behich	16	12	1990	M
10167	17	Daniel	Arzani	4	1	1999	M
11675	18	Danny	Vukovic	27	3	1985	M
87852	19	Josh	Risdon	27	7	1992	M
83849	20	Trent	Sainsbury	5	1	1992	M
83198	21	Dimitri	Petratos	10	11	1992	M
34822	22	Jackson	Irvine	7	3	1993	M
45548	23	Tom	Rogic	16	12	1992	M
6338	11	Yannick	Carrasco	4	9	1993	M
88715	13	Koen	Casteels	25	6	1992	M
22930	15	Thomas	Meunier	12	9	1991	M
74337	16	Thorgan	Hazard	29	3	1993	M
47906	17	Youri	Tielemans	7	5	1997	M
85472	20	Dedryck	Boyata	28	11	1990	M
13975	21	Michy	Batshuayi	2	10	1993	M
73834	23	Leander	Dendoncker	15	4	1995	M
21531	1	not applicable	Alisson	2	10	1992	M
84301	3	not applicable	Miranda	7	9	1984	M
77556	4	Pedro	Geromel	21	9	1985	M
2305	5	not applicable	Casemiro	23	2	1992	M
65498	6	Filipe	Luís	9	8	1985	M
17082	7	Douglas	Costa	14	9	1990	M
49997	8	Renato	Augusto	8	2	1988	M
92004	9	Gabriel	Jesus	3	4	1997	M
37171	11	Philippe	Coutinho	12	6	1992	M
76060	13	not applicable	Marquinhos	14	5	1994	M
40137	14	not applicable	Danilo	15	7	1991	M
66815	16	not applicable	Cássio	6	6	1987	M
74941	18	not applicable	Fred	5	3	1993	M
37877	20	Roberto	Firmino	2	10	1991	M
87266	21	not applicable	Taison	13	1	1988	M
97493	22	not applicable	Fagner	11	6	1989	M
89248	23	not applicable	Ederson	17	8	1993	M
26542	3	Óscar	Murillo	18	4	1988	M
17988	5	Wilmar	Barrios	16	10	1993	M
74655	9	Radamel	Falcao	10	2	1986	M
43196	13	Yerry	Mina	23	9	1994	M
16245	14	Luis	Muriel	16	4	1991	M
7807	15	Mateus	Uribe	21	3	1991	M
61424	16	Jefferson	Lerma	25	10	1994	M
7796	17	Johan	Mojica	21	8	1992	M
37614	18	Farid	Díaz	20	7	1983	M
59950	19	Miguel	Borja	26	1	1993	M
75090	21	José	Izquierdo	7	7	1992	M
29212	22	José Fernando	Cuadrado	1	6	1985	M
38594	23	Davinson	Sánchez	12	6	1996	M
63865	4	Ian	Smith	6	3	1998	M
10740	8	Bryan	Oviedo	18	2	1990	M
781	9	Daniel	Colindres	10	1	1985	M
58669	11	Johan	Venegas	27	11	1988	M
42644	13	Rodney	Wallace	17	6	1988	M
71100	15	Francisco	Calvo	8	7	1992	M
37984	19	Kendall	Waston	1	1	1988	M
33347	20	David	Guzmán	18	2	1990	M
71751	22	Kenner	Gutiérrez	9	6	1989	M
92476	23	Leonel	Moreira	2	4	1990	M
99988	1	Dominik	Livaković	9	1	1995	M
86004	3	Ivan	Strinić	17	7	1987	M
65182	9	Andrej	Kramarić	19	6	1991	M
89113	12	Lovre	Kalinić	3	4	1990	M
65146	13	Tin	Jedvaj	28	11	1995	M
57763	14	Filip	Bradarić	11	1	1992	M
57922	15	Duje	Ćaleta-Car	17	9	1996	M
12763	16	Nikola	Kalinić	5	1	1988	M
14891	20	Marko	Pjaca	6	5	1995	M
89420	22	Josip	Pivarić	30	1	1989	M
58755	1	Kasper	Schmeichel	5	11	1986	M
71525	2	Michael	Krohn-Dehli	6	6	1983	M
3748	3	Jannik	Vestergaard	3	8	1992	M
9856	5	Jonas	Knudsen	16	9	1992	M
18923	6	Andreas	Christensen	10	4	1996	M
57615	8	Thomas	Delaney	3	9	1991	M
67216	9	Nicolai	Jørgensen	15	1	1991	M
85579	11	Martin	Braithwaite	5	6	1991	M
72592	12	Kasper	Dolberg	6	10	1997	M
61976	13	Mathias	Jørgensen	23	4	1990	M
44386	14	Henrik	Dalsgaard	27	7	1989	M
65946	15	Viktor	Fischer	9	6	1994	M
28357	16	Jonas	Lössl	1	2	1989	M
11588	17	Jens	Stryger Larsen	21	2	1991	M
79590	18	Lukas	Lerager	12	7	1993	M
60880	19	Lasse	Schöne	27	5	1986	M
8442	20	Yussuf	Poulsen	15	6	1994	M
29053	21	Andreas	Cornelius	16	3	1993	M
35930	22	Frederik	Rønnow	4	8	1992	M
18907	23	Pione	Sisto	4	2	1995	M
32448	1	Essam	El Hadary	15	1	1973	M
83293	2	Ali	Gabr	1	1	1989	M
49004	3	Ahmed	Elmohamady	9	9	1987	M
13030	4	Omar	Gaber	30	1	1992	M
50801	5	Sam	Morsy	10	9	1991	M
81689	6	Ahmed	Hegazi	25	1	1991	M
44093	7	Ahmed	Fathy	10	11	1984	M
77754	8	Tarek	Hamed	24	10	1988	M
37703	9	Marwan	Mohsen	26	2	1989	M
75890	10	Mohamed	Salah	15	6	1992	M
24653	11	not applicable	Kahraba	13	4	1994	M
2028	12	Ayman	Ashraf	9	4	1991	M
29161	13	Mohamed	Abdel Shafy	1	7	1985	M
91291	14	Ramadan	Sobhi	23	1	1997	M
41789	15	Mahmoud	Hamdy	1	6	1995	M
49027	16	Sherif	Ekramy	10	7	1983	M
60871	17	Mohamed	Elneny	11	7	1992	M
96547	18	not applicable	Shikabala	5	3	1986	M
74320	19	Abdallah	El Said	13	7	1985	M
8628	20	Saad	Samir	1	4	1989	M
82223	21	not applicable	Trézéguet	1	10	1994	M
99805	22	Amr	Warda	17	9	1993	M
86080	23	Mohamed	El Shenawy	18	12	1988	M
70618	1	Jordan	Pickford	7	3	1994	M
74071	2	Kyle	Walker	28	5	1990	M
48480	3	Danny	Rose	2	7	1990	M
31219	4	Eric	Dier	15	1	1994	M
92628	5	John	Stones	28	5	1994	M
2465	6	Harry	Maguire	5	3	1993	M
63620	7	Jesse	Lingard	15	12	1992	M
58924	9	Harry	Kane	28	7	1993	M
74242	11	Jamie	Vardy	11	1	1987	M
25937	12	Kieran	Trippier	19	9	1990	M
38372	13	Jack	Butland	10	3	1993	M
16053	17	Fabian	Delph	21	11	1989	M
9246	18	Ashley	Young	9	7	1985	M
59837	19	Marcus	Rashford	31	10	1997	M
83363	20	Dele	Alli	11	4	1996	M
84745	21	Ruben	Loftus-Cheek	23	1	1996	M
5318	22	Trent	Alexander-Arnold	7	10	1998	M
89070	23	Nick	Pope	19	4	1992	M
60652	2	Benjamin	Pavard	28	3	1996	M
17174	3	Presnel	Kimpembe	13	8	1995	M
67297	5	Samuel	Umtiti	14	11	1993	M
7153	8	Thomas	Lemar	12	11	1995	M
64077	10	Kylian	Mbappé	20	12	1998	M
97778	11	Ousmane	Dembélé	15	5	1997	M
54461	12	Corentin	Tolisso	3	8	1994	M
98287	13	N'Golo	Kanté	29	3	1991	M
69451	15	Steven	Nzonzi	15	12	1988	M
40789	17	Adil	Rami	27	12	1985	M
20754	18	Nabil	Fekir	18	7	1993	M
73306	19	Djibril	Sidibé	29	7	1992	M
71285	20	Florian	Thauvin	26	1	1993	M
84424	21	Lucas	Hernandez	14	2	1996	M
71816	22	Benjamin	Mendy	17	7	1994	M
81466	23	Alphonse	Areola	27	2	1993	M
69785	2	Marvin	Plattenhardt	26	1	1992	M
77118	3	Jonas	Hector	27	5	1990	M
19339	9	Timo	Werner	6	3	1996	M
94447	11	Marco	Reus	31	5	1989	M
81947	12	Kevin	Trapp	8	7	1990	M
79409	14	Leon	Goretzka	6	2	1995	M
48737	15	Niklas	Süle	3	9	1995	M
51201	16	Antonio	Rüdiger	3	3	1993	M
30316	18	Joshua	Kimmich	8	2	1995	M
62162	19	Sebastian	Rudy	28	2	1990	M
50679	20	Julian	Brandt	2	5	1996	M
8896	21	İlkay	Gündoğan	24	10	1990	M
3367	22	Marc-André	ter Stegen	30	4	1992	M
37032	1	Hannes Þór	Halldórsson	27	4	1984	M
27331	2	Birkir Már	Sævarsson	11	11	1984	M
68348	3	Samúel	Friðjónsson	22	2	1996	M
69192	4	Albert	Guðmundsson	15	6	1997	M
82839	5	Sverrir Ingi	Ingason	5	8	1993	M
13758	6	Ragnar	Sigurðsson	19	6	1986	M
3161	7	Jóhann Berg	Guðmundsson	27	10	1990	M
90675	8	Birkir	Bjarnason	27	5	1988	M
73258	9	Björn Bergmann	Sigurðarson	26	2	1991	M
83367	10	Gylfi	Sigurðsson	8	9	1989	M
70085	11	Alfreð	Finnbogason	1	2	1989	M
93803	12	Frederik	Schram	19	1	1995	M
77257	13	Rúnar Alex	Rúnarsson	18	2	1995	M
45419	14	Kári	Árnason	13	10	1982	M
9507	15	Hólmar Örn	Eyjólfsson	6	8	1990	M
5450	16	Ólafur Ingi	Skúlason	1	4	1983	M
58772	17	Aron	Gunnarsson	22	4	1989	M
28803	18	Hörður Björgvin	Magnússon	11	2	1993	M
38514	19	Rúrik	Gíslason	25	2	1988	M
7013	20	Emil	Hallfreðsson	29	6	1984	M
48976	21	Arnór Ingvi	Traustason	30	4	1993	M
31941	22	Jón Daði	Böðvarsson	25	5	1992	M
2559	23	Ari Freyr	Skúlason	14	5	1987	M
20998	1	Alireza	Beiranvand	21	9	1992	M
4541	2	Mehdi	Torabi	10	9	1994	M
98747	4	Rouzbeh	Cheshmi	24	7	1993	M
74098	5	Milad	Mohammadi	29	9	1993	M
95374	6	Saeid	Ezatolahi	1	10	1996	M
29864	8	Morteza	Pouraliganji	19	4	1992	M
60139	9	Omid	Ebrahimi	16	9	1987	M
24531	11	Vahid	Amiri	2	4	1988	M
29185	12	Mohammad Rashid	Mazaheri	18	5	1989	M
26022	13	Mohammad Reza	Khanzadeh	11	5	1991	M
87786	14	Saman	Ghoddos	6	9	1993	M
85860	17	Mehdi	Taremi	18	7	1992	M
15905	19	Majid	Hosseini	20	6	1996	M
9113	20	Sardar	Azmoun	1	1	1995	M
80505	22	Amir	Abedzadeh	26	4	1993	M
47137	23	Ramin	Rezaeian	21	3	1990	M
28595	2	Naomichi	Ueda	24	10	1994	M
46176	3	Gen	Shoji	11	12	1992	M
53282	6	Wataru	Endo	9	2	1993	M
99817	7	Gaku	Shibasaki	28	5	1992	M
54138	8	Genki	Haraguchi	9	5	1991	M
2595	11	Takashi	Usami	6	5	1992	M
11411	12	Masaaki	Higashiguchi	12	5	1986	M
36278	13	Yoshinori	Muto	15	7	1992	M
89984	14	Takashi	Inui	2	6	1988	M
82154	18	Ryota	Oshima	23	1	1993	M
76596	20	Tomoaki	Makino	11	5	1987	M
20127	23	Kosuke	Nakamura	27	2	1995	M
76750	2	Hugo	Ayala	31	3	1987	M
1730	3	Carlos	Salcedo	29	9	1993	M
64299	5	Érick	Gutiérrez	15	6	1995	M
9951	6	Jonathan	dos Santos	26	4	1990	M
96694	17	Jesús Manuel	Corona	6	1	1993	M
26546	21	Edson	Álvarez	24	10	1997	M
24705	22	Hirving	Lozano	30	7	1995	M
80088	23	Jesús	Gallardo	15	8	1994	M
50688	1	Yassine	Bounou	5	4	1991	M
45288	2	Achraf	Hakimi	4	11	1998	M
54550	3	Hamza	Mendyl	21	10	1997	M
99089	4	Manuel	da Costa	6	5	1986	M
53270	5	Medhi	Benatia	17	4	1987	M
26068	6	Romain	Saïss	26	3	1990	M
70715	7	Hakim	Ziyech	19	3	1993	M
62364	8	Karim	El Ahmadi	27	1	1985	M
46107	9	Ayoub	El Kaabi	25	6	1993	M
64125	10	Younès	Belhanda	25	2	1990	M
46039	11	Fayçal	Fajr	1	8	1988	M
15566	12	Munir	Mohamedi	10	5	1989	M
15199	13	Khalid	Boutaïb	24	4	1987	M
46553	14	Mbark	Boussoufa	15	8	1984	M
58822	15	Youssef	Aït Bennasser	7	7	1996	M
37696	16	Nordin	Amrabat	31	3	1987	M
98153	17	Nabil	Dirar	25	2	1986	M
87199	18	Amine	Harit	18	6	1997	M
42517	19	Youssef	En-Nesyri	1	6	1997	M
60872	20	Aziz	Bouhaddouz	30	3	1987	M
71023	21	Sofyan	Amrabat	21	8	1996	M
88869	22	Ahmed Reda	Tagnaouti	5	4	1996	M
54137	23	Mehdi	Carcela	1	7	1989	M
51723	1	Ikechukwu	Ezenwa	16	10	1988	M
1347	2	Brian	Idowu	18	5	1992	M
61893	4	Wilfred	Ndidi	16	12	1996	M
15870	5	William	Troost-Ekong	1	9	1993	M
65978	6	Leon	Balogun	28	6	1988	M
62455	8	Peter	Etebo	9	11	1995	M
14651	9	Odion	Ighalo	16	6	1989	M
75724	12	Shehu	Abdullahi	12	3	1993	M
55236	13	Simeon	Nwankwo	7	5	1992	M
8253	14	Kelechi	Iheanacho	10	3	1996	M
33715	15	Joel	Obi	22	5	1991	M
83020	16	Daniel	Akpeyi	8	3	1986	M
40578	18	Alex	Iwobi	3	5	1996	M
40341	19	John	Ogu	20	4	1988	M
27669	20	Chidozie	Awaziem	1	1	1997	M
12630	21	Tyronne	Ebuehi	16	12	1995	M
7594	23	Francis	Uzoho	28	10	1998	M
77521	1	Jaime	Penedo	26	9	1981	M
72819	2	Michael Amir	Murillo	11	2	1996	M
53385	3	Harold	Cummings	1	3	1992	M
91455	4	Fidel	Escobar	9	1	1995	M
2886	5	Román	Torres	20	3	1986	M
32575	6	Gabriel	Gómez	29	5	1984	M
76850	7	Blas	Pérez	13	3	1981	M
10561	8	Édgar	Bárcenas	23	10	1993	M
78106	9	Gabriel	Torres	31	10	1988	M
9945	10	Ismael	Díaz	12	5	1997	M
6696	11	Armando	Cooper	26	11	1987	M
91983	12	José	Calderón	14	8	1985	M
77892	13	Adolfo	Machado	14	2	1985	M
48670	14	Valentín	Pimentel	30	5	1991	M
44505	15	Erick	Davis	31	3	1991	M
52444	16	Abdiel	Arroyo	13	12	1993	M
22016	17	Luis	Ovalle	7	9	1988	M
3144	18	Luis	Tejada	28	3	1982	M
67176	19	Ricardo	Ávila	4	2	1997	M
24760	20	Aníbal	Godoy	10	2	1990	M
34448	21	José Luis	Rodríguez	19	6	1998	M
80905	22	Álex	Rodríguez	5	8	1990	M
76368	23	Felipe	Baloy	24	2	1981	M
83518	1	Pedro	Gallese	23	2	1990	M
86020	2	Alberto	Rodríguez	31	3	1984	M
2351	3	Aldo	Corzo	20	5	1989	M
56647	4	Anderson	Santamaría	10	1	1992	M
36397	5	Miguel	Araujo	24	10	1994	M
53701	6	Miguel	Trauco	25	8	1992	M
88592	7	Paolo	Hurtado	27	7	1990	M
4154	8	Christian	Cueva	23	11	1991	M
29117	9	Paolo	Guerrero	1	1	1984	M
70132	10	Jefferson	Farfán	26	10	1984	M
16977	11	Raúl	Ruidíaz	25	7	1990	M
1594	12	Carlos	Cáceda	27	9	1991	M
82532	13	Renato	Tapia	28	7	1995	M
96067	14	Andy	Polo	29	9	1994	M
70241	15	Christian	Ramos	4	11	1988	M
77391	16	Wilder	Cartagena	23	9	1994	M
47833	17	Luis	Advíncula	2	3	1990	M
39610	18	André	Carrillo	14	6	1991	M
61528	19	Yoshimar	Yotún	7	4	1990	M
5862	20	Edison	Flores	14	5	1994	M
9633	21	José	Carvallo	1	3	1986	M
23264	22	Nilson	Loyola	26	10	1994	M
59720	23	Pedro	Aquino	13	4	1995	M
31606	1	Wojciech	Szczęsny	18	4	1990	M
70794	2	Michał	Pazdan	21	9	1987	M
61813	3	Artur	Jędrzejczyk	4	11	1987	M
40820	4	Thiago	Cionek	21	4	1986	M
10172	5	Jan	Bednarek	12	4	1996	M
57157	6	Jacek	Góralski	21	9	1992	M
12381	7	Arkadiusz	Milik	28	2	1994	M
64111	8	Karol	Linetty	2	2	1995	M
549	9	Robert	Lewandowski	21	8	1988	M
45449	10	Grzegorz	Krychowiak	29	1	1990	M
64261	11	Kamil	Grosicki	8	6	1988	M
40292	12	Bartosz	Białkowski	6	7	1987	M
19545	13	Maciej	Rybus	19	8	1989	M
65144	14	Łukasz	Teodorczyk	3	6	1991	M
29046	15	Kamil	Glik	3	2	1988	M
57494	16	Jakub	Błaszczykowski	14	12	1985	M
27417	17	Sławomir	Peszko	19	2	1985	M
42160	18	Bartosz	Bereszyński	12	7	1992	M
32165	19	Piotr	Zieliński	20	5	1994	M
32858	20	Łukasz	Piszczek	3	6	1985	M
9584	21	Rafał	Kurzawa	29	1	1993	M
23468	23	Dawid	Kownacki	14	3	1997	M
99900	4	Manuel	Fernandes	5	2	1986	M
67578	5	Raphaël	Guerreiro	22	12	1993	M
18665	6	José	Fonte	22	12	1983	M
33280	9	André	Silva	6	11	1995	M
31133	10	João	Mário	19	1	1993	M
34205	11	Bernardo	Silva	10	8	1994	M
93586	12	Anthony	Lopes	1	10	1990	M
10712	13	Rúben	Dias	14	5	1997	M
35081	15	Ricardo	Pereira	6	10	1993	M
39584	16	Bruno	Fernandes	8	9	1994	M
65199	17	Gonçalo	Guedes	29	11	1996	M
63951	18	Gelson	Martins	11	5	1995	M
521	19	Mário	Rui	27	5	1991	M
95670	20	Ricardo	Quaresma	26	9	1983	M
46272	21	not applicable	Cédric	31	8	1991	M
72710	23	Adrien	Silva	15	3	1989	M
17872	2	Mário	Fernandes	19	9	1990	M
82792	3	Ilya	Kutepov	29	7	1993	M
43675	6	Denis	Cheryshev	26	12	1990	M
17415	7	Daler	Kuzyayev	15	1	1993	M
20571	8	Yury	Gazinsky	20	7	1989	M
18383	10	Fyodor	Smolov	9	2	1990	M
5922	11	Roman	Zobnin	11	2	1994	M
37265	12	Andrey	Lunyov	13	11	1991	M
47851	13	Fyodor	Kudryashov	5	4	1987	M
11064	15	Aleksei	Miranchuk	17	10	1995	M
23559	16	Anton	Miranchuk	17	10	1995	M
22778	17	Aleksandr	Golovin	30	5	1996	M
33785	20	Vladimir	Gabulov	19	10	1983	M
20163	21	Aleksandr	Yerokhin	13	10	1989	M
37840	22	Artem	Dzyuba	22	8	1988	M
64597	23	Igor	Smolnikov	8	8	1988	M
61496	1	Abdullah	Al-Mayouf	23	1	1987	M
91707	2	Mansoor	Al-Harbi	19	10	1987	M
95345	3	Osama	Hawsawi	31	3	1984	M
87284	4	Ali	Al-Bulaihi	21	11	1989	M
31004	5	Omar	Hawsawi	27	9	1985	M
94422	6	Mohammed	Al-Breik	15	9	1992	M
93688	7	Salman	Al-Faraj	1	8	1989	M
23568	8	Yahya	Al-Shehri	26	6	1990	M
84563	9	Hattan	Bahebri	16	7	1992	M
83734	10	Mohammad	Al-Sahlawi	10	1	1987	M
4434	11	Abdulmalek	Al-Khaibri	13	3	1986	M
91268	12	Mohamed	Kanno	22	9	1994	M
45457	13	Yasser	Al-Shahrani	25	5	1992	M
99177	14	Abdullah	Otayf	3	8	1992	M
82537	15	Abdullah	Al-Khaibari	16	8	1996	M
77853	16	Housain	Al-Mogahwi	24	3	1988	M
66636	17	Taisir	Al-Jassim	25	7	1984	M
70583	18	Salem	Al-Dawsari	19	8	1991	M
24301	19	Fahad	Al-Muwallad	14	9	1994	M
36522	20	Muhannad	Assiri	14	10	1986	M
40442	21	Yasser	Al-Mosailem	27	2	1984	M
85438	22	Mohammed	Al-Owais	10	10	1991	M
30394	23	Motaz	Hawsawi	17	2	1992	M
44035	1	Abdoulaye	Diallo	30	3	1992	M
93828	2	Adama	Mbengue	1	12	1993	M
47321	3	Kalidou	Koulibaly	20	6	1991	M
29883	4	Kara	Mbodji	22	11	1989	M
40621	5	Idrissa	Gueye	26	9	1989	M
91655	6	Salif	Sané	25	8	1990	M
38799	7	Moussa	Sow	19	1	1986	M
55140	8	Cheikhou	Kouyaté	21	12	1989	M
29136	9	Mame Biram	Diouf	16	12	1987	M
79299	10	Sadio	Mané	10	4	1992	M
51960	11	Cheikh	N'Doye	29	3	1986	M
55298	12	Youssouf	Sabaly	5	3	1993	M
12707	13	Alfred	N'Diaye	6	3	1990	M
94596	14	Moussa	Konaté	3	4	1993	M
22102	15	Diafra	Sakho	24	12	1989	M
17986	16	Khadim	N'Diaye	5	4	1985	M
15988	17	Badou	Ndiaye	27	10	1990	M
37935	18	Ismaïla	Sarr	25	2	1998	M
23774	19	M'Baye	Niang	19	12	1994	M
44044	20	Keita	Baldé	8	3	1995	M
35711	21	Lamine	Gassama	20	10	1989	M
57411	22	Moussa	Wagué	4	10	1998	M
53694	23	Alfred	Gomis	5	9	1993	M
54492	3	Duško	Tošić	19	1	1985	M
44932	4	Luka	Milivojević	7	4	1991	M
75924	5	Uroš	Spajić	13	2	1993	M
58363	7	Andrija	Živković	11	7	1996	M
40618	8	Aleksandar	Prijović	21	4	1990	M
85696	9	Aleksandar	Mitrović	16	9	1994	M
33390	10	Dušan	Tadić	20	11	1988	M
35773	12	Predrag	Rajković	31	10	1995	M
30283	13	Miloš	Veljković	26	9	1995	M
12935	14	Milan	Rodić	2	4	1991	M
57535	15	Nikola	Milenković	12	10	1997	M
89573	16	Marko	Grujić	13	4	1996	M
80738	17	Filip	Kostić	1	11	1992	M
79900	18	Nemanja	Radonjić	15	2	1996	M
62033	19	Luka	Jović	23	12	1997	M
27744	20	Sergej	Milinković-Savić	27	2	1995	M
66184	21	Nemanja	Matić	1	8	1988	M
45505	22	Adem	Ljajić	29	9	1991	M
72770	23	Marko	Dmitrović	24	1	1992	M
51199	3	Seung-hyun	Jung	3	4	1994	M
26051	4	Ban-suk	Oh	20	5	1988	M
18598	5	Young-sun	Yun	4	10	1988	M
9338	8	Se-jong	Ju	30	10	1990	M
2947	10	Seung-woo	Lee	6	1	1998	M
58692	11	Hee-chan	Hwang	26	1	1996	M
2609	12	Min-woo	Kim	25	2	1990	M
91889	14	Chul	Hong	17	9	1990	M
64292	15	Woo-young	Jung	14	12	1989	M
93920	17	Jae-sung	Lee	10	8	1992	M
34018	18	Seon-min	Moon	9	6	1992	M
37612	20	Hyun-soo	Jang	28	9	1991	M
29757	21	Jin-hyeon	Kim	6	7	1987	M
26566	22	Yo-han	Go	10	3	1988	M
4157	23	Hyeon-woo	Jo	25	9	1991	M
71071	2	Dani	Carvajal	11	1	1992	M
15848	4	not applicable	Nacho	18	1	1990	M
52837	7	not applicable	Saúl	21	11	1994	M
339	9	not applicable	Rodrigo	6	3	1991	M
92520	10	not applicable	Thiago	11	4	1991	M
97275	11	Lucas	Vázquez	1	7	1991	M
76837	12	Álvaro	Odriozola	14	12	1995	M
51443	13	Kepa	Arrizabalaga	3	10	1994	M
11593	16	Nacho	Monreal	26	2	1986	M
60554	17	Iago	Aspas	1	8	1987	M
9400	20	Marco	Asensio	21	1	1996	M
52418	22	not applicable	Isco	21	4	1992	M
26943	1	Robin	Olsen	8	1	1990	M
29833	2	Mikael	Lustig	13	12	1986	M
31431	3	Victor	Lindelöf	17	7	1994	M
34998	4	Andreas	Granqvist	16	4	1985	M
90129	5	Martin	Olsson	17	5	1988	M
30993	6	Ludwig	Augustinsson	21	4	1994	M
74946	7	Sebastian	Larsson	6	6	1985	M
20019	8	Albin	Ekdal	28	7	1989	M
82967	9	Marcus	Berg	17	8	1986	M
4686	10	Emil	Forsberg	23	10	1991	M
89934	11	John	Guidetti	15	4	1992	M
46890	12	Karl-Johan	Johnsson	28	1	1990	M
19366	13	Gustav	Svensson	7	2	1987	M
42015	14	Filip	Helander	22	4	1993	M
15887	15	Oscar	Hiljemark	28	6	1992	M
28801	16	Emil	Krafth	2	8	1994	M
78477	17	Viktor	Claesson	2	1	1992	M
46506	18	Pontus	Jansson	13	2	1991	M
24357	19	Marcus	Rohdén	11	5	1991	M
10221	20	Ola	Toivonen	3	7	1986	M
73907	21	Jimmy	Durmaz	22	3	1989	M
8312	22	Isaac	Kiese Thelin	24	6	1992	M
8714	23	Kristoffer	Nordfeldt	23	6	1989	M
67914	3	François	Moubandje	21	6	1990	M
19193	4	Nico	Elvedi	30	9	1996	M
23925	5	Manuel	Akanji	19	7	1995	M
19075	7	Breel	Embolo	14	2	1997	M
68060	8	Remo	Freuler	15	4	1992	M
1729	12	Yvon	Mvogo	6	6	1994	M
71840	14	Steven	Zuber	17	8	1991	M
83560	17	Denis	Zakaria	20	11	1996	M
55710	1	Farouk	Ben Mustapha	1	7	1989	M
62629	2	Syam	Ben Youssef	31	3	1989	M
3191	3	Yohan	Benalouane	28	3	1987	M
81706	4	Yassine	Meriah	2	7	1993	M
88818	5	Oussama	Haddadi	28	1	1992	M
96029	6	Rami	Bedoui	19	1	1990	M
14196	7	Saîf-Eddine	Khaoui	27	4	1995	M
94563	8	Fakhreddine	Ben Youssef	23	6	1991	M
75361	9	Anice	Badri	18	9	1990	M
42223	10	Wahbi	Khazri	8	2	1991	M
11879	11	Dylan	Bronn	19	6	1995	M
38981	12	Ali	Maâloul	1	1	1990	M
90867	13	Ferjani	Sassi	18	3	1992	M
21962	14	Mohamed Amine	Ben Amor	3	5	1992	M
12859	15	Ahmed	Khalil	21	12	1994	M
25989	16	Aymen	Mathlouthi	14	9	1984	M
47815	17	Ellyes	Skhiri	10	5	1995	M
77301	18	Bassem	Srarfi	25	6	1997	M
2778	19	Saber	Khalifa	14	10	1986	M
9569	20	Ghailene	Chaalali	28	2	1994	M
39664	21	Hamdi	Nagguez	28	10	1992	M
57303	22	Mouez	Hassen	5	3	1995	M
69793	23	Naïm	Sliti	27	7	1992	M
78932	4	Guillermo	Varela	24	3	1993	M
13847	5	Carlos	Sánchez	2	12	1984	M
58791	6	Rodrigo	Bentancur	25	6	1997	M
85532	8	Nahitan	Nández	28	12	1995	M
62594	10	Giorgian	De Arrascaeta	1	6	1994	M
46020	12	Martín	Campaña	29	5	1989	M
39902	13	Gastón	Silva	5	3	1994	M
47386	14	Lucas	Torreira	11	2	1996	M
46785	15	Matías	Vecino	24	8	1991	M
83211	17	Diego	Laxalt	7	2	1993	M
70671	18	Maxi	Gómez	14	8	1996	M
33500	20	Jonathan	Urretaviscaya	19	3	1990	M
7642	2	Agustina	Barroso	20	5	1993	F
75744	3	Eliana	Stábile	26	11	1993	F
55287	4	Adriana	Sachs	25	12	1993	F
6775	5	Vanesa	Santana	3	9	1990	F
97512	6	Aldana	Cometti	3	3	1996	F
58375	7	Yael	Oviedo	22	5	1992	F
45264	8	Ruth	Bravo	6	3	1992	F
70181	9	Sole	Jaimes	20	1	1989	F
89102	10	Estefanía	Banini	21	6	1990	F
15565	11	Florencia	Bonsegundo	14	7	1993	F
7960	12	Gaby	Garton	27	5	1990	F
54801	13	Virginia	Gómez	26	2	1991	F
30464	14	Miriam	Mayorga	20	11	1989	F
14114	16	Lorena	Benítez	3	12	1998	F
23167	19	Mariana	Larroquette	24	10	1992	F
75102	20	Dalila	Ippólito	24	3	2002	F
69102	21	Natalie	Juncos	28	12	1990	F
38768	22	Milagros	Menéndez	23	3	1997	F
58308	23	Solana	Pereyra	5	4	1999	F
58909	2	Gema	Simon	19	7	1990	F
23508	3	Aivi	Luik	18	3	1985	F
95706	5	Karly	Roestbakken	17	1	2001	F
36494	6	Chloe	Logarzo	22	12	1994	F
6221	12	Teagan	Micah	20	10	1997	F
74493	15	Emily	Gielnik	13	5	1992	F
25968	17	Mary	Fowler	14	2	2003	F
60982	21	Ellie	Carpenter	28	4	2000	F
33399	22	Amy	Harrison	21	4	1996	F
96976	3	not applicable	Daiane	7	9	1997	F
34305	9	not applicable	Debinha	20	10	1991	F
9384	12	not applicable	Aline	6	7	1982	F
84606	13	Letícia	Santos	2	12	1994	F
78371	14	not applicable	Kathellen	26	4	1996	F
49703	15	not applicable	Camila	10	10	1994	F
13960	18	not applicable	Luana	2	5	1993	F
95343	19	not applicable	Ludmila	11	12	1994	F
84502	23	not applicable	Geyse	27	3	1998	F
10691	6	Estelle	Johnson	21	7	1988	F
64407	13	Charlène	Meyong	19	11	1998	F
50711	16	Isabelle	Mambingo	10	4	1985	F
96889	19	Marlyse	Ngo Ndoumbouk	3	1	1985	F
82188	21	Alexandra	Takounda	7	7	2000	F
84073	22	Michaela	Abam	13	6	1997	F
11758	23	Marthe	Ongmahan	12	6	1992	F
35887	4	Shelina	Zadorsky	24	8	1992	F
71404	5	not applicable	Quinn	11	8	1995	F
68361	6	Deanne	Rose	3	3	1999	F
15733	7	Julia	Grosso	29	8	2000	F
56274	8	Jayde	Riviere	22	1	2001	F
54415	9	Jordyn	Huitema	8	5	2001	F
94074	14	Gabrielle	Carle	12	10	1998	F
26193	15	Nichelle	Prince	19	2	1995	F
48464	16	Janine	Beckie	20	8	1994	F
63984	18	Kailen	Sheridan	16	7	1995	F
57858	20	Shannon	Woeller	31	1	1990	F
20435	21	Sabrina	D'Angelo	11	5	1993	F
15991	22	Lindsay	Agnew	31	3	1995	F
89067	23	Jenna	Hellstrom	2	4	1995	F
63450	1	Christiane	Endler	23	7	1991	F
37018	2	Rocío	Soto	21	9	1993	F
18316	3	Carla	Guerrero	23	12	1987	F
55571	4	Francisca	Lara	29	7	1990	F
19507	5	Valentina	Díaz	30	3	2001	F
35338	6	Claudia	Soto	6	7	1993	F
11345	7	María José	Rojas	17	12	1987	F
77951	8	Karen	Araya	16	10	1990	F
93835	9	María José	Urrutia	17	12	1993	F
9681	10	Yanara	Aedo	5	8	1993	F
39388	11	Yessenia	López	20	10	1990	F
81462	12	Natalia	Campos	12	1	1992	F
83621	13	Javiera	Grez	11	7	2000	F
95101	14	Daniela	Pardo	5	9	1988	F
36548	15	Su Helen	Galaz	27	5	1991	F
40766	16	Fernanda	Pinilla	6	11	1993	F
41132	17	Javiera	Toro	22	4	1998	F
71609	18	Camila	Sáez	17	10	1994	F
27240	19	Yessenia	Huenteo	30	10	1992	F
1247	20	Daniela	Zamora	13	11	1990	F
6087	21	Rosario	Balmaceda	23	3	1999	F
10126	22	Elisa	Durán	16	1	2002	F
13952	23	Ryann	Torrero	1	9	1990	F
9049	1	Huan	Xu	6	3	1999	F
56033	3	Yuping	Lin	28	2	1992	F
44771	9	Li	Yang	26	2	1993	F
29138	12	Shimeng	Peng	12	5	1998	F
4204	13	Yan	Wang	22	8	1991	F
2184	14	Ying	Wang	18	11	1997	F
58097	15	Duan	Song	2	8	1995	F
45842	16	Wen	Li	21	2	1989	F
81118	18	Xiaolin	Bi	18	9	1989	F
27178	21	Wei	Yao	1	9	1997	F
75216	22	Guiping	Luo	20	4	1993	F
80652	23	Yanqiu	Liu	31	12	1995	F
20638	4	Keira	Walsh	8	4	1997	F
42847	6	Millie	Bright	21	8	1993	F
62542	7	Nikita	Parris	10	3	1994	F
60046	12	Demi	Stokes	12	12	1991	F
71247	14	Leah	Williamson	29	3	1997	F
25548	15	Abbie	McManus	14	1	1993	F
6258	17	Rachel	Daly	6	12	1991	F
55143	19	Georgia	Stanway	3	1	1999	F
69367	21	Mary	Earps	7	3	1993	F
41857	22	Beth	Mead	9	5	1995	F
23605	23	Lucy	Staniforth	2	10	1992	F
54578	1	Solène	Durand	20	11	1994	F
46773	2	Ève	Périsset	24	12	1994	F
16125	4	Marion	Torrent	17	4	1992	F
82432	5	Aïssatou	Tounkara	16	3	1995	F
22001	7	Sakina	Karchaoui	26	1	1996	F
89699	8	Grace	Geyoro	2	7	1997	F
56864	12	Emelyne	Laurent	4	11	1998	F
44380	13	Valérie	Gauvin	1	6	1996	F
71185	14	Charlotte	Bilbault	5	6	1990	F
79996	18	Viviane	Asseyi	20	11	1993	F
65933	20	Delphine	Cascarino	5	2	1997	F
68800	21	Pauline	Peyraud-Magnin	17	3	1992	F
47772	22	Julie	Debever	18	4	1988	F
17184	23	Maéva	Clemaron	10	11	1992	F
16505	2	Carolin	Simon	24	11	1992	F
88232	3	Kathrin	Hendrich	6	4	1992	F
58658	5	Marina	Hegering	17	4	1990	F
70499	6	Lena	Oberdorf	19	12	2001	F
25269	7	Lea	Schüller	12	11	1997	F
25113	9	Svenja	Huth	25	1	1991	F
29496	14	Johanna	Elsig	1	11	1992	F
91637	15	Giulia	Gwinn	2	7	1999	F
2802	16	Linda	Dallmann	2	9	1994	F
51855	19	Klara	Bühl	7	12	2000	F
83353	20	Lina	Magull	15	8	1994	F
7343	21	Merle	Frohms	28	1	1995	F
85891	22	Turid	Knaak	24	1	1991	F
25793	23	Sara	Doorsoun	17	11	1991	F
22236	1	Laura	Giuliani	6	6	1993	F
51292	2	Valentina	Bergamaschi	22	1	1997	F
55953	3	Sara	Gama	27	3	1989	F
33581	4	Aurora	Galli	13	12	1996	F
2903	5	Elena	Linari	15	4	1994	F
14034	6	Martina	Rosucci	9	5	1992	F
31008	7	Alia	Guagni	1	10	1987	F
80703	8	Alice	Parisi	11	12	1990	F
26735	9	Daniela	Sabatino	26	6	1985	F
49416	10	Cristiana	Girelli	23	4	1990	F
47343	11	Barbara	Bonansea	13	6	1991	F
35550	12	Chiara	Marchitelli	4	5	1985	F
94445	13	Elisa	Bartoli	7	5	1991	F
89389	14	Stefania	Tarenzi	29	2	1988	F
83704	15	Annamaria	Serturini	13	5	1998	F
67555	16	Laura	Fusetti	8	10	1990	F
89652	17	Lisa	Boattin	3	5	1997	F
62883	18	Ilaria	Mauro	22	5	1988	F
21343	19	Valentina	Giacinti	2	1	1994	F
86989	20	Linda	Tucceri Cimini	4	4	1991	F
34581	21	Valentina	Cernoia	22	6	1991	F
44980	22	Rosalia	Pipitone	3	8	1985	F
91740	23	Manuela	Giugliano	18	8	1997	F
66845	1	Sydney	Schneider	31	8	1999	F
1019	2	Lauren	Silver	22	3	1993	F
18051	3	Chanel	Hudson-Marks	14	9	1997	F
93187	4	Chantelle	Swaby	6	8	1998	F
81939	5	Konya	Plummer	2	8	1997	F
24113	6	Havana	Solaun	23	3	1993	F
18193	7	Chinyelu	Asher	20	5	1993	F
32999	8	Ashleigh	Shim	11	11	1993	F
57962	9	Marlo	Sweatman	1	12	1994	F
5768	10	Jody	Brown	16	4	2002	F
52873	11	Khadija	Shaw	31	1	1997	F
57799	12	Sashana	Campbell	2	3	1991	F
74959	13	Nicole	McClure	16	11	1989	F
87532	14	Deneisha	Blackwood	7	3	1997	F
47069	15	Tiffany	Cameron	16	10	1991	F
72963	16	Dominique	Bond-Flasza	11	9	1996	F
32663	17	Allyson	Swaby	3	10	1996	F
76996	18	Trudi	Carter	18	11	1994	F
16488	19	Toriana	Patterson	2	2	1994	F
80618	20	Cheyna	Matthews	10	11	1993	F
24941	21	Olufolasade	Adamolekun	21	2	2001	F
76650	22	Mireya	Grey	7	9	1998	F
66224	23	Yazmeen	Jamieson	17	3	1998	F
31788	1	Sakiko	Ikeda	8	9	1992	F
50809	5	Nana	Ichise	4	8	1997	F
42768	6	Hina	Sugita	31	1	1997	F
44627	7	Emi	Nakajima	27	9	1990	F
84768	11	Rikako	Kobayashi	21	7	1997	F
49873	12	Moeka	Minami	7	12	1998	F
95935	13	Saori	Takarada	27	12	1999	F
12315	14	Yui	Hasegawa	29	1	1997	F
63894	15	Yuka	Momiki	9	4	1996	F
16222	16	Asato	Miyagawa	24	2	1998	F
45582	17	Narumi	Miura	3	7	1997	F
14314	18	Ayaka	Yamashita	29	9	1995	F
69786	19	Jun	Endo	24	5	2000	F
1320	20	Kumi	Yokoyama	13	8	1993	F
74836	21	Chika	Hirao	31	12	1996	F
54839	22	Risa	Shimizu	15	6	1996	F
14621	23	Shiori	Miyake	13	10	1995	F
91488	5	Kika	van Es	11	10	1991	F
85842	12	Victoria	Pelova	3	6	1999	F
83256	13	Renate	Jansen	7	12	1990	F
96101	14	Jackie	Groenen	17	12	1994	F
79057	15	Inessa	Kaagman	17	4	1996	F
8372	16	Lize	Kop	17	3	1998	F
4880	17	Ellen	Jansen	6	10	1992	F
77151	18	Danique	Kerkdijk	1	5	1996	F
82354	21	Lineth	Beerensteyn	11	10	1996	F
21421	22	Liza	van der Most	8	10	1993	F
76331	5	Nicole	Stratford	1	2	1989	F
33543	15	Sarah	Morton	28	8	1998	F
89867	18	Stephanie	Skilton	27	10	1994	F
3449	19	Paige	Satchell	13	4	1998	F
79424	21	Victoria	Esson	6	3	1991	F
24097	22	Olivia	Chance	5	10	1993	F
47156	23	Nadia	Olla	7	2	2000	F
63064	2	Amarachi	Okoronkwo	12	12	1992	F
93238	7	Anam	Imo	30	11	2000	F
44672	11	Chinaza	Uchendu	3	12	1997	F
64606	12	Uchenna	Kanu	27	6	1997	F
30731	15	Rasheedat	Ajibade	8	12	1999	F
28304	16	Chiamaka	Nnadozie	8	12	2000	F
25251	19	Chinwendu	Ihezuo	30	4	1997	F
76647	20	Chidinma	Okeke	11	8	2000	F
85488	22	Alice	Ogebe	30	3	1995	F
57821	4	Stine	Hovland	31	1	1991	F
48596	5	Synne	Skinnes Hansen	12	8	1995	F
22963	8	Vilde	Bøe Risa	13	7	1995	F
22811	10	Caroline Graham	Hansen	18	2	1995	F
63803	13	Therese	Åsland	26	8	1995	F
56682	14	Ingrid Syrstad	Engen	29	4	1998	F
12306	15	Amalie	Eikeland	26	8	1995	F
77652	16	Guro	Reiten	26	7	1994	F
82215	18	Frida	Maanum	16	7	1999	F
44649	19	Cecilie Redisch	Kvamme	9	11	1995	F
77852	21	Karina	Sævik	24	3	1996	F
88386	22	Emilie	Nautnes	13	1	1999	F
91984	23	Oda Maria Hove	Bogstad	24	4	1996	F
76817	1	Lee	Alexander	23	9	1991	F
4980	2	Kirsty	Smith	6	1	1994	F
25596	3	Nicola	Docherty	23	8	1992	F
4543	4	Rachel	Corsie	17	8	1989	F
86688	5	Jen	Beattie	13	5	1991	F
6994	6	Joanne	Love	6	12	1985	F
93076	7	Hayley	Lauder	4	6	1990	F
7522	8	Kim	Little	29	6	1990	F
16255	9	Caroline	Weir	20	6	1995	F
24104	10	Leanne	Crichton	6	8	1987	F
56744	11	Lisa	Evans	21	5	1992	F
91493	12	Shannon	Lynn	22	10	1985	F
98441	13	Jane	Ross	18	9	1989	F
77204	14	Chloe	Arthur	21	1	1995	F
35487	15	Sophie	Howard	17	9	1993	F
25443	16	Christie	Murray	3	5	1990	F
24424	17	Joelle	Murray	7	11	1986	F
91406	18	Claire	Emslie	8	3	1994	F
90678	19	Lana	Clelland	26	1	1993	F
92690	20	Fiona	Brown	31	3	1995	F
14478	21	Jenna	Fife	1	12	1995	F
39315	22	Erin	Cuthbert	19	7	1998	F
10240	23	Lizzie	Arnot	1	3	1996	F
7569	1	Mapaseka	Mpuru	9	4	1998	F
11369	2	Lebogang	Ramalepe	3	12	1991	F
11968	3	Nothando	Vilakazi	28	10	1988	F
45038	4	Noko	Matlou	30	9	1985	F
13569	5	Janine	van Wyk	17	4	1987	F
97934	6	Mamello	Makhabane	24	2	1988	F
51606	7	Karabo	Dhlamini	18	9	2001	F
20364	8	Ode	Fulutudilu	6	2	1990	F
47455	9	Amanda	Mthandi	23	5	1996	F
65355	10	Linda	Motlhalo	1	7	1998	F
46109	11	Thembi	Kgatlana	2	5	1996	F
55720	12	Jermaine	Seoposenwe	12	10	1993	F
24675	13	Bambanani	Mbane	12	3	1990	F
14454	14	Tiisetso	Makhubela	24	4	1997	F
28995	15	Refiloe	Jane	4	8	1992	F
92858	16	Andile	Dlamini	2	9	1992	F
19745	17	Leandra	Smeda	22	7	1989	F
75054	18	Bongeka	Gamede	22	5	1999	F
27801	19	Kholosa	Biyana	16	4	1994	F
88898	20	Kaylin	Swart	30	9	1994	F
79237	21	Busisiwe	Ndimeni	25	6	1991	F
16808	22	Rhoda	Mulaudzi	2	12	1989	F
51920	23	Sibulele	Holweni	28	4	2001	F
34923	1	Ga-ae	Kang	10	12	1990	F
12406	3	Yeong-a	Jeong	9	12	1990	F
23175	7	Min-a	Lee	8	11	1991	F
86842	9	Mi-ra	Moon	28	2	1992	F
56762	13	Min-ji	Yeo	27	4	1993	F
32041	14	Dam-yeong	Shin	2	10	1993	F
41848	15	Young-ju	Lee	22	4	1992	F
53137	16	Sel-gi	Jang	31	5	1994	F
70854	18	Min-jeong	Kim	12	9	1996	F
41156	21	Bo-ram	Jung	22	7	1991	F
47230	22	Hwa-yeon	Son	15	3	1997	F
84114	23	Chae-rim	Kang	23	3	1998	F
89115	3	Leila	Ouahabi	22	3	1993	F
19703	9	Mariona	Caldentey	19	3	1996	F
16202	12	Patricia	Guijarro	17	5	1998	F
75163	16	María Pilar	León	13	6	1995	F
22924	17	Lucía	García	14	7	1998	F
71200	18	Aitana	Bonmatí	18	1	1998	F
25615	20	Andrea	Pereira	19	9	1993	F
84258	21	Andrea	Falcón	28	2	1997	F
14224	22	Nahikari	García	10	3	1997	F
47065	23	María Asunción	Quiñones	29	10	1996	F
7053	2	Jonna	Andersson	2	1	1993	F
56701	4	Hanna	Glas	16	4	1993	F
76573	6	Magdalena	Eriksson	8	9	1993	F
93553	7	Madelen	Janogy	12	11	1995	F
48545	8	Lina	Hurtig	15	9	1995	F
62190	11	Stina	Blackstenius	5	2	1996	F
96469	12	Jennifer	Falk	26	4	1993	F
84995	14	Julia	Roddar	16	2	1992	F
24130	15	Nathalie	Björn	4	5	1997	F
89508	16	Julia	Zigiotti Olme	24	12	1997	F
99138	18	Fridolina	Rolfö	24	11	1993	F
33464	19	Anna	Anvegård	10	5	1997	F
28884	20	Mimmi	Larsson	9	4	1994	F
25946	21	Zećira	Mušović	26	5	1996	F
46356	2	Saengkoon	Kanjanaporn	18	7	1996	F
98000	8	Miranda	Nild	1	4	1997	F
49535	11	Chuchuen	Sudarat	19	6	1997	F
40231	14	Pengngam	Saowalak	30	11	1996	F
74376	15	Waenngoen	Orapin	7	10	1995	F
23511	19	Sornsai	Pitsamai	19	1	1989	F
23564	22	Tiffany	Sornpao	22	5	1998	F
34799	23	Philawan	Phornphirun	8	4	1999	F
6125	2	Mallory	Pugh	29	4	1998	F
59472	3	Sam	Mewis	9	10	1992	F
97292	7	Abby	Dahlkemper	13	5	1993	F
46428	9	Lindsey	Horan	26	5	1994	F
71623	12	Tierna	Davidson	19	9	1998	F
41858	14	Emily	Sonnett	25	11	1993	F
65982	16	Rose	Lavelle	14	5	1995	F
91711	19	Crystal	Dunn	3	7	1992	F
98384	20	Allie	Long	13	8	1987	F
3657	21	Adrianna	Franch	12	11	1990	F
66473	22	Jessica	McDonald	28	2	1988	F
652	2	Juan	Foyth	12	1	1998	M
91431	4	Gonzalo	Montiel	1	1	1997	M
27582	5	Leandro	Paredes	29	6	1994	M
29298	6	Germán	Pezzella	27	6	1991	M
37314	7	Rodrigo	De Paul	24	5	1994	M
19776	9	Julián	Álvarez	31	1	2000	M
36188	12	Gerónimo	Rulli	20	5	1992	M
79650	13	Cristian	Romero	27	4	1998	M
40147	14	Exequiel	Palacios	5	10	1998	M
92353	15	Ángel	Correa	9	3	1995	M
56659	16	Thiago	Almada	26	4	2001	M
10231	17	Papu	Gómez	15	2	1988	M
3265	18	Guido	Rodríguez	12	4	1994	M
71343	20	Alexis	Mac Allister	24	12	1998	M
81505	22	Lautaro	Martínez	22	8	1997	M
13162	23	Emiliano	Martínez	2	9	1992	M
10739	24	Enzo	Fernández	17	1	2001	M
23070	25	Lisandro	Martínez	18	1	1998	M
84430	26	Nahuel	Molina	6	4	1998	M
9062	3	Nathaniel	Atkinson	13	6	1999	M
88273	4	Kye	Rowles	24	6	1998	M
24134	5	Fran	Karačić	12	5	1996	M
34915	6	Marco	Tilio	23	8	2001	M
82945	10	Ajdin	Hrustic	5	7	1996	M
61979	11	Awer	Mabil	15	9	1995	M
30596	12	Andrew	Redmayne	13	1	1989	M
51406	14	Riley	McGree	2	11	1998	M
91029	15	Mitchell	Duke	18	1	1991	M
64249	17	Cameron	Devlin	7	6	1998	M
89217	19	Harry	Souttar	22	10	1998	M
68599	20	Thomas	Deng	20	3	1997	M
5864	21	Garang	Kuol	15	9	2004	M
82010	23	Craig	Goodwin	16	12	1991	M
53409	24	Joel	King	30	10	2000	M
67089	25	Jason	Cummings	1	8	1995	M
27035	26	Keanu	Baccus	7	6	1998	M
75820	3	Arthur	Theate	25	5	2000	M
61413	4	Wout	Faes	3	4	1998	M
95312	17	Leandro	Trossard	4	12	1994	M
21652	18	Amadou	Onana	16	8	2001	M
81997	20	Hans	Vanaken	24	8	1992	M
56069	21	Timothy	Castagne	5	12	1995	M
61810	22	Charles	De Ketelaere	10	3	2001	M
70691	24	Loïs	Openda	16	2	2000	M
29578	25	Jérémy	Doku	27	5	2002	M
56669	26	Zeno	Debast	24	10	2003	M
97698	6	Alex	Sandro	26	1	1991	M
5164	7	Lucas	Paquetá	27	8	1997	M
68016	9	not applicable	Richarlison	10	5	1997	M
83169	11	not applicable	Raphinha	14	12	1996	M
66020	12	not applicable	Weverton	13	12	1987	M
55590	14	Éder	Militão	18	1	1998	M
77071	15	not applicable	Fabinho	23	10	1993	M
26953	16	Alex	Telles	15	12	1992	M
74688	17	Bruno	Guimarães	16	11	1997	M
37860	19	not applicable	Antony	24	2	2000	M
92812	20	Vinícius	Júnior	12	7	2000	M
6446	21	not applicable	Rodrygo	9	1	2001	M
42740	22	Éverton	Ribeiro	10	4	1989	M
14060	24	not applicable	Bremer	18	3	1997	M
15197	25	not applicable	Pedro	20	6	1997	M
70483	26	Gabriel	Martinelli	18	6	2001	M
22927	1	Simon	Ngapandouetnbu	12	4	2003	M
32773	2	Jerome	Ngom Mbekeli	30	9	1998	M
74894	4	Christopher	Wooh	18	9	2001	M
36707	5	Gaël	Ondoua	4	11	1995	M
27913	6	Moumi	Ngamaleu	9	7	1994	M
68058	7	Georges-Kévin	Nkoudou	13	2	1995	M
38355	8	André-Frank	Zambo Anguissa	16	11	1995	M
39239	9	Jean-Pierre	Nsame	1	5	1993	M
51549	11	Christian	Bassogog	18	10	1995	M
20259	12	Karl	Toko Ekambi	14	9	1992	M
63923	14	Samuel	Gouet	14	12	1997	M
29115	15	Pierre	Kunde	26	7	1995	M
70357	16	Devis	Epassy	2	2	1993	M
80930	17	Olivier	Mbaizo	15	8	1997	M
34633	18	Martin	Hongla	16	3	1998	M
47677	19	Collins	Fai	13	8	1992	M
39394	20	Bryan	Mbeumo	7	8	1999	M
59303	21	Jean-Charles	Castelletto	26	1	1995	M
62618	22	Olivier	Ntcham	9	2	1996	M
67127	23	André	Onana	2	4	1996	M
2759	24	Enzo	Ebosse	11	3	1999	M
55367	25	Nouhou	Tolo	23	6	1997	M
25904	26	Souaibou	Marou	3	12	2000	M
94317	1	Dayne	St. Clair	9	5	1997	M
12635	2	Alistair	Johnston	8	10	1998	M
55821	3	Sam	Adekugbe	16	1	1995	M
31806	4	Kamal	Miller	16	5	1997	M
89710	5	Steven	Vitória	11	1	1987	M
65386	6	Samuel	Piette	12	11	1994	M
28794	7	Stephen	Eustáquio	21	12	1996	M
32574	8	Liam	Fraser	13	2	1998	M
58061	9	Lucas	Cavallini	28	12	1992	M
35706	10	Junior	Hoilett	5	6	1990	M
96259	11	Tajon	Buchanan	8	2	1999	M
83822	12	Iké	Ugbo	21	9	1998	M
3472	13	Atiba	Hutchinson	8	2	1983	M
72399	14	Mark-Anthony	Kaye	2	12	1994	M
85670	15	Ismaël	Koné	16	6	2002	M
61949	16	James	Pantemis	21	2	1997	M
1925	17	Cyle	Larin	17	4	1995	M
46263	18	Milan	Borjan	23	10	1987	M
46358	19	Alphonso	Davies	2	11	2000	M
48340	20	Jonathan	David	14	1	2000	M
27541	21	Jonathan	Osorio	12	6	1992	M
42390	22	Richie	Laryea	7	1	1995	M
809	23	Liam	Millar	27	9	1999	M
49915	24	David	Wotherspoon	16	1	1990	M
21099	25	Derek	Cornelius	25	11	1997	M
71727	26	Joel	Waterman	24	1	1996	M
57150	2	Daniel	Chacón	11	4	2001	M
65777	3	Juan Pablo	Vargas	6	6	1995	M
80986	4	Keysher	Fuller	12	7	1994	M
2556	7	Anthony	Contreras	29	1	2000	M
9889	9	Jewison	Bennette	15	6	2004	M
12179	13	Gerson	Torres	28	8	1997	M
32622	14	Youstin	Salas	17	6	1996	M
39281	16	Carlos	Martínez	30	3	1999	M
3616	18	Esteban	Alvarado	28	4	1989	M
44957	20	Brandon	Aguilera	28	6	2003	M
1994	21	Douglas	López	21	9	1998	M
37189	22	Rónald	Matarrita	9	7	1994	M
81142	23	Patrick	Sequeira	1	3	1999	M
23993	24	Roan	Wilson	1	5	2002	M
14872	25	Anthony	Hernández	11	10	2001	M
22631	26	Álvaro	Zamora	9	3	2002	M
91350	2	Josip	Stanišić	2	4	2000	M
95766	3	Borna	Barišić	10	11	1992	M
1196	5	Martin	Erlić	24	1	1998	M
64353	7	Lovro	Majer	17	1	1998	M
32870	12	Ivo	Grbić	18	1	1996	M
22160	13	Nikola	Vlašić	4	10	1997	M
31643	14	Marko	Livaja	26	8	1993	M
89948	15	Mario	Pašalić	9	2	1995	M
46461	16	Bruno	Petković	16	9	1994	M
99461	17	Ante	Budimir	22	7	1991	M
26942	18	Mislav	Oršić	29	12	1992	M
84190	19	Borna	Sosa	21	1	1998	M
58420	20	Joško	Gvardiol	23	1	2002	M
16484	22	Josip	Juranović	16	8	1995	M
94815	23	Ivica	Ivušić	1	2	1995	M
57417	24	Josip	Šutalo	28	2	2000	M
67668	25	Luka	Sučić	8	9	2002	M
86466	26	Kristijan	Jakić	14	5	1997	M
43705	2	Joachim	Andersen	31	5	1996	M
49454	3	Victor	Nelsson	14	10	1998	M
39995	5	Joakim	Mæhle	20	5	1997	M
26593	7	Mathias	Jensen	1	1	1996	M
82313	11	Andreas Skov	Olsen	29	12	1999	M
82877	13	Rasmus	Kristensen	11	7	1997	M
57782	14	Mikkel	Damsgaard	3	7	2000	M
56182	15	Christian	Nørgaard	10	3	1994	M
7304	16	Oliver	Christensen	22	3	1999	M
93781	18	Daniel	Wass	31	5	1989	M
59609	19	Jonas	Wind	7	2	1999	M
98199	23	Pierre-Emile	Højbjerg	5	8	1995	M
76468	24	Robert	Skov	20	5	1996	M
70516	25	Jesper	Lindstrøm	29	2	2000	M
92135	26	Alexander	Bah	9	12	1997	M
56347	1	Hernán	Galíndez	30	3	1987	M
96347	2	Félix	Torres	11	1	1997	M
29713	3	Piero	Hincapié	9	1	2002	M
22286	4	Robert	Arboleda	22	10	1991	M
75628	5	José	Cifuentes	12	3	1999	M
49934	6	William	Pacho	16	10	2001	M
52697	7	Pervis	Estupiñán	21	1	1998	M
16576	9	Ayrton	Preciado	17	7	1994	M
34543	10	Romario	Ibarra	24	9	1994	M
44851	11	Michael	Estrada	7	4	1996	M
39347	12	Moisés	Ramírez	9	9	2000	M
6545	14	Xavier	Arreaga	28	9	1994	M
11495	15	Ángel	Mena	21	1	1988	M
78091	16	Jeremy	Sarmiento	16	6	2002	M
62543	17	Ángelo	Preciado	18	2	1998	M
4237	18	Diego	Palacios	12	7	1999	M
13973	19	Gonzalo	Plata	1	11	2000	M
56839	20	Sebas	Méndez	26	4	1997	M
28364	21	Alan	Franco	21	8	1998	M
82216	23	Moisés	Caicedo	2	11	2001	M
69217	24	Djorkaeff	Reasco	18	1	1999	M
73694	25	Jackson	Porozo	4	8	2000	M
2839	26	Kevin	Rodríguez	4	3	2000	M
84787	4	Declan	Rice	14	1	1999	M
21153	7	Jack	Grealish	10	9	1995	M
43567	14	Kalvin	Phillips	2	12	1995	M
76287	16	Conor	Coady	25	2	1993	M
76842	17	Bukayo	Saka	5	9	2001	M
90012	19	Mason	Mount	10	1	1999	M
10501	20	Phil	Foden	28	5	2000	M
50034	21	Ben	White	8	10	1997	M
15674	22	Jude	Bellingham	29	6	2003	M
62368	23	Aaron	Ramsdale	14	5	1998	M
22844	24	Callum	Wilson	27	2	1992	M
95181	25	James	Maddison	23	11	1996	M
46540	26	Conor	Gallagher	6	2	2000	M
91324	3	Axel	Disasi	11	3	1998	M
78484	5	Jules	Koundé	12	11	1998	M
32431	6	Matteo	Guendouzi	14	4	1999	M
54517	8	Aurélien	Tchouaméni	27	1	2000	M
92987	12	Randal	Kolo Muani	5	12	1998	M
23304	13	Youssouf	Fofana	10	1	1999	M
57401	14	Adrien	Rabiot	3	4	1995	M
465	15	Jordan	Veretout	1	3	1993	M
7089	17	William	Saliba	24	3	2001	M
3945	18	Dayot	Upamecano	27	10	1998	M
6614	20	Kingsley	Coman	13	6	1996	M
9867	22	Théo	Hernandez	6	10	1997	M
86920	24	Ibrahima	Konaté	25	5	1999	M
80996	25	Eduardo	Camavinga	10	11	2002	M
13613	26	Marcus	Thuram	6	8	1997	M
20804	3	David	Raum	22	4	1998	M
11933	5	Thilo	Kehrer	21	9	1996	M
77743	7	Kai	Havertz	11	6	1999	M
46246	9	Niclas	Füllkrug	9	2	1993	M
75989	10	Serge	Gnabry	14	7	1995	M
47182	14	Jamal	Musiala	26	2	2003	M
89863	16	Lukas	Klostermann	3	6	1996	M
18188	18	Jonas	Hofmann	14	7	1992	M
39464	19	Leroy	Sané	11	1	1996	M
63385	20	Christian	Günter	28	2	1993	M
71859	23	Nico	Schlotterbeck	1	12	1999	M
5901	24	Karim	Adeyemi	18	1	2002	M
69200	25	Armel	Bella-Kotchap	11	12	2001	M
4137	26	Youssoufa	Moukoko	20	11	2004	M
51990	1	Lawrence	Ati-Zigi	29	11	1996	M
12913	2	Tariq	Lamptey	30	9	2000	M
8359	3	Denis	Odoi	27	5	1988	M
50142	4	Mohammed	Salisu	17	4	1999	M
7875	5	Thomas	Partey	13	6	1993	M
70145	6	Elisha	Owusu	7	11	1997	M
62854	7	Abdul Fatawu	Issahaku	8	3	2004	M
92252	8	Daniel-Kofi	Kyereh	8	3	1996	M
72363	11	Osman	Bukari	13	12	1998	M
16148	12	Ibrahim	Danlad	2	12	2002	M
13639	13	Daniel	Afriyie	26	6	2001	M
28517	14	Gideon	Mensah	18	7	1998	M
9991	15	Joseph	Aidoo	29	9	1995	M
36638	16	Abdul	Manaf Nurudeen	8	2	1999	M
94579	17	Baba	Rahman	2	7	1994	M
82956	18	Daniel	Amartey	21	12	1994	M
53967	19	Iñaki	Williams	15	6	1994	M
23821	20	Mohammed	Kudus	2	8	2000	M
21820	21	Salis	Abdul Samed	26	3	2000	M
33325	22	Kamaldeen	Sulemana	15	2	2002	M
59808	23	Alexander	Djiku	9	8	1994	M
20467	24	Kamal	Sowah	9	1	2000	M
14179	25	Antoine	Semenyo	7	1	2000	M
36105	26	Alidu	Seidu	4	6	2000	M
84382	2	Sadegh	Moharrami	1	3	1996	M
97838	4	Shojae	Khalilzadeh	14	5	1989	M
17784	12	Payam	Niazmand	6	4	1995	M
74612	13	Hossein	Kanaanizadegan	23	3	1994	M
45653	17	Ali	Gholizadeh	10	3	1996	M
68842	18	Ali	Karimi	11	2	1994	M
42215	21	Ahmad	Nourollahi	1	2	1993	M
28492	24	Hossein	Hosseini	30	6	1992	M
62858	25	Abolfazl	Jalali	26	6	1998	M
45981	2	Miki	Yamane	22	12	1993	M
77382	3	Shogo	Taniguchi	15	7	1991	M
35225	4	Ko	Itakura	27	1	1997	M
58907	8	Ritsu	Dōan	16	6	1998	M
22633	9	Kaoru	Mitoma	20	5	1997	M
5559	10	Takumi	Minamino	16	1	1995	M
39942	11	Takefusa	Kubo	4	6	2001	M
75751	13	Hidemasa	Morita	10	5	1995	M
86909	14	Junya	Ito	9	3	1993	M
62952	15	Daichi	Kamada	5	8	1996	M
68429	16	Takehiro	Tomiyasu	5	11	1998	M
82447	17	Ao	Tanaka	10	9	1998	M
46913	18	Takuma	Asano	10	11	1994	M
44328	20	Shuto	Machino	30	9	1999	M
57586	21	Ayase	Ueda	28	8	1998	M
77827	23	Daniel	Schmidt	3	2	1992	M
64056	24	Yuki	Soma	25	2	1997	M
30206	25	Daizen	Maeda	20	10	1997	M
41902	26	Hiroki	Ito	12	5	1999	M
38529	2	Néstor	Araujo	29	8	1991	M
36212	3	César	Montes	24	2	1997	M
9877	5	Johan	Vásquez	22	10	1998	M
96510	6	Gerardo	Arteaga	7	9	1998	M
26412	7	Luis	Romo	5	6	1995	M
19618	8	Carlos	Rodríguez	3	1	1997	M
64182	10	Alexis	Vega	25	11	1997	M
51689	11	Rogelio	Funes Mori	5	3	1991	M
96662	12	Rodolfo	Cota	3	7	1987	M
95198	17	Orbelín	Pineda	24	3	1996	M
24062	19	Jorge	Sánchez	10	12	1997	M
49482	20	Henry	Martín	18	11	1992	M
81433	21	Uriel	Antuna	21	8	1997	M
49806	24	Luis	Chávez	15	1	1996	M
73491	25	Roberto	Alvarado	7	9	1998	M
9058	26	Kevin	Álvarez	15	1	1999	M
9614	3	Noussair	Mazraoui	14	11	1997	M
47490	5	Nayef	Aguerd	30	3	1996	M
40619	8	Azzedine	Ounahi	19	4	2000	M
90423	9	Abderrazak	Hamdallah	17	12	1990	M
94093	10	Anass	Zaroury	7	11	2000	M
5265	11	Abdelhamid	Sabiri	28	11	1996	M
87409	13	Ilias	Chair	30	10	1997	M
48295	14	Zakaria	Aboukhlal	18	2	2000	M
23330	15	Selim	Amallah	15	11	1996	M
21052	16	Abde	Ezzalzouli	17	12	2001	M
59033	17	Sofiane	Boufal	17	9	1993	M
14026	18	Jawad	El Yamiq	29	2	1992	M
52013	20	Achraf	Dari	6	5	1999	M
5216	21	Walid	Cheddira	22	1	1998	M
80656	23	Bilal	El Khannous	10	5	2004	M
597	24	Badr	Benoun	30	9	1993	M
91543	25	Yahia	Attiyat Allah	2	3	1995	M
86644	26	Yahya	Jabrane	18	6	1991	M
18921	1	Remko	Pasveer	8	11	1983	M
74111	2	Jurriën	Timber	17	6	2001	M
73572	3	Matthijs	de Ligt	12	8	1999	M
56029	4	Virgil	van Dijk	8	7	1991	M
64438	5	Nathan	Aké	18	2	1995	M
44799	7	Steven	Bergwijn	8	10	1997	M
28911	8	Cody	Gakpo	7	5	1999	M
64551	9	Luuk	de Jong	27	8	1990	M
10326	11	Steven	Berghuis	19	12	1991	M
57903	12	Noa	Lang	17	6	1999	M
15282	13	Justin	Bijlow	22	1	1998	M
42078	14	Davy	Klaassen	21	2	1993	M
55965	15	Marten	de Roon	29	3	1991	M
78630	16	Tyrell	Malacia	17	8	1999	M
57087	18	Vincent	Janssen	15	6	1994	M
95036	19	Wout	Weghorst	7	8	1992	M
35705	20	Teun	Koopmeiners	28	2	1998	M
17688	21	Frenkie	de Jong	12	5	1997	M
97615	22	Denzel	Dumfries	18	4	1996	M
82000	23	Andries	Noppert	7	4	1994	M
95763	24	Kenneth	Taylor	16	5	2002	M
34458	25	Xavi	Simons	21	4	2003	M
70227	26	Jeremie	Frimpong	10	12	2000	M
17099	2	Matty	Cash	7	8	1997	M
76995	4	Mateusz	Wieteska	11	2	1997	M
14593	6	Krystian	Bielik	4	1	1998	M
44699	8	Damian	Szymański	16	6	1995	M
17943	12	Łukasz	Skorupski	5	5	1991	M
83610	13	Jakub	Kamiński	5	6	2002	M
44780	14	Jakub	Kiwior	15	2	2000	M
85630	16	Karol	Świderski	23	1	1997	M
31085	17	Szymon	Żurkowski	25	9	1997	M
65512	19	Sebastian	Szymański	10	5	1999	M
40498	21	Nicola	Zalewski	23	1	2002	M
90913	22	Kamil	Grabara	8	1	1999	M
11013	23	Krzysztof	Piątek	1	7	1995	M
23437	24	Przemysław	Frankowski	12	4	1995	M
42168	25	Robert	Gumny	4	6	1998	M
2071	26	Michał	Skóraś	15	2	2000	M
41603	2	Diogo	Dalot	18	3	1999	M
46583	6	João	Palhinha	9	7	1995	M
17931	11	João	Félix	10	11	1999	M
85204	12	José	Sá	17	1	1993	M
98929	13	Danilo	Pereira	9	9	1991	M
27349	15	Rafael	Leão	10	6	1999	M
89266	16	not applicable	Vitinha	13	2	2000	M
22983	18	Rúben	Neves	13	3	1997	M
87003	19	Nuno	Mendes	19	6	2002	M
16736	20	João	Cancelo	27	5	1994	M
5304	21	Ricardo	Horta	15	9	1994	M
54827	22	Diogo	Costa	19	9	1999	M
57759	23	Matheus	Nunes	27	8	1998	M
5289	24	António	Silva	30	10	2003	M
78787	25	not applicable	Otávio	9	2	1995	M
41647	26	Gonçalo	Ramos	20	6	2001	M
70879	1	Saad	Al-Sheeb	19	2	1990	M
52	2	not applicable	Ró-Ró	6	8	1990	M
1258	3	Abdelkarim	Hassan	28	8	1993	M
90689	4	Mohammed	Waad	18	9	1999	M
42663	5	Tarek	Salman	5	12	1997	M
97800	6	Abdulaziz	Hatem	1	1	1990	M
57100	7	Ahmed	Alaaeldin	31	1	1993	M
51678	8	Ali	Assadalla	19	1	1993	M
17048	9	Mohammed	Muntari	20	12	1993	M
38732	10	Hassan	Al-Haydos	11	12	1990	M
47319	11	Akram	Afif	18	11	1996	M
95754	12	Karim	Boudiaf	16	9	1990	M
32949	13	Musab	Kheder	1	1	1993	M
33804	14	Homam	Ahmed	25	8	1999	M
15161	15	Bassam	Al-Rawi	16	12	1997	M
12810	16	Boualem	Khoukhi	9	7	1990	M
1077	17	Ismaeel	Mohammad	5	4	1990	M
54495	18	Khalid	Muneer	24	2	1998	M
1930	19	Almoez	Ali	19	8	1996	M
43921	20	Salem	Al-Hajri	10	4	1996	M
75618	21	Yousef	Hassan	24	5	1996	M
28811	22	Meshaal	Barsham	14	2	1998	M
63532	23	Assim	Madibo	22	10	1996	M
93316	24	Naif	Al-Hadhrami	18	7	2001	M
22110	25	Jassem	Gaber	20	2	2002	M
26637	26	Mostafa	Meshaal	28	3	2001	M
6659	1	Mohammed	Al-Rubaie	14	8	1997	M
6789	2	Sultan	Al-Ghannam	6	5	1994	M
20388	3	Abdullah	Madu	15	7	1993	M
12335	4	Abdulelah	Al-Amri	15	1	1997	M
20216	8	Abdulellah	Al-Malki	11	10	1994	M
89845	9	Firas	Al-Buraikan	14	5	2000	M
37308	11	Saleh	Al-Shehri	1	11	1993	M
8125	12	Saud	Abdulhamid	18	7	1999	M
45413	15	Ali	Al-Hassan	4	3	1997	M
87569	16	Sami	Al-Najei	7	2	1997	M
93173	17	Hassan	Al-Tambakti	9	2	1999	M
76864	18	Nawaf	Al-Abed	26	1	1990	M
45581	20	Abdulrahman	Al-Aboud	1	6	1995	M
67035	22	Nawaf	Al-Aqidi	10	5	2000	M
10907	24	Nasser	Al-Dawsari	19	12	1998	M
40487	25	Haitham	Asiri	25	3	2001	M
6750	26	Riyadh	Sharahili	28	4	1993	M
99821	1	Seny	Dieng	23	11	1994	M
11718	2	Formose	Mendy	2	1	2001	M
90626	4	Pape Abou	Cissé	14	9	1995	M
96697	6	Nampalys	Mendy	23	6	1992	M
86937	7	Nicolas	Jackson	20	6	2001	M
33622	9	Boulaye	Dia	16	11	1996	M
66635	10	Moussa	N'Diaye	18	6	2002	M
61416	11	Pathé	Ciss	16	3	1994	M
86095	12	Fodé	Ballo-Touré	3	1	1997	M
33958	13	Iliman	Ndiaye	6	3	2000	M
54506	14	Ismail	Jakobs	17	8	1999	M
9292	15	Krépin	Diatta	25	2	1999	M
45399	16	Édouard	Mendy	1	3	1992	M
76835	17	Pape Matar	Sarr	14	9	2002	M
27280	19	Famara	Diédhiou	15	12	1992	M
88928	20	Bamba	Dieng	23	3	2000	M
77769	22	Abdou	Diallo	4	5	1996	M
92891	24	Moustapha	Name	5	5	1995	M
37001	25	Mamadou	Loum	30	12	1996	M
45280	26	Pape	Gueye	24	1	1999	M
98435	2	Strahinja	Pavlović	24	5	2001	M
55665	3	Strahinja	Eraković	22	1	2001	M
89598	6	Nemanja	Maksimović	26	1	1995	M
24610	8	Nemanja	Gudelj	16	11	1991	M
19069	13	Stefan	Mitrović	22	5	1990	M
70515	15	Srđan	Babić	22	4	1996	M
78056	16	Saša	Lukić	13	8	1996	M
63293	18	Dušan	Vlahović	28	1	2000	M
9530	19	Uroš	Račić	17	3	1998	M
79754	21	Filip	Đuričić	30	1	1992	M
54211	22	Darko	Lazović	15	9	1990	M
24245	23	Vanja	Milinković-Savić	20	2	1997	M
67641	24	Ivan	Ilić	17	3	2001	M
82143	25	Filip	Mladenović	15	8	1991	M
88529	2	Yoon	Jong-gyu	20	3	1998	M
82889	3	Kim	Jin-su	13	6	1992	M
14360	4	Kim	Min-jae	15	11	1996	M
67516	6	Hwang	In-beom	20	9	1996	M
32599	8	Paik	Seung-ho	17	3	1997	M
87169	9	Cho	Gue-sung	25	1	1998	M
49090	12	Song	Bum-keun	15	10	1997	M
61172	13	Son	Jun-ho	12	5	1992	M
7233	15	Kim	Moon-hwan	1	8	1995	M
92710	16	Hwang	Ui-jo	28	8	1992	M
10357	17	Na	Sang-ho	12	8	1996	M
87514	18	Lee	Kang-in	19	2	2001	M
57511	20	Kwon	Kyung-won	31	1	1992	M
88360	22	Kwon	Chang-hoon	30	6	1994	M
66969	23	Kim	Tae-hwan	24	7	1989	M
5917	24	Cho	Yu-min	17	11	1996	M
94500	25	Jeong	Woo-yeong	20	9	1999	M
97485	26	Song	Min-kyu	12	9	1999	M
92513	1	Robert	Sánchez	18	11	1997	M
37420	3	Eric	García	9	1	2001	M
16333	4	Pau	Torres	16	1	1997	M
86871	6	Marcos	Llorente	30	1	1995	M
29274	7	Álvaro	Morata	23	10	1992	M
88433	9	not applicable	Gavi	5	8	2004	M
31301	11	Ferran	Torres	29	2	2000	M
68218	12	Nico	Williams	12	7	2002	M
33433	13	David	Raya	15	9	1995	M
49008	14	Alejandro	Balde	18	10	2003	M
87958	15	Hugo	Guillamón	31	1	2000	M
62341	16	not applicable	Rodri	22	6	1996	M
46898	17	Yeremy	Pino	20	10	2002	M
30405	19	Carlos	Soler	2	1	1997	M
40007	21	Dani	Olmo	7	5	1998	M
81427	22	Pablo	Sarabia	11	5	1992	M
94271	23	Unai	Simón	11	6	1997	M
99025	24	Aymeric	Laporte	27	5	1994	M
33854	25	Ansu	Fati	31	10	2002	M
24897	26	not applicable	Pedri	25	11	2002	M
29932	2	Edimilson	Fernandes	15	4	1996	M
38927	3	Silvan	Widmer	5	3	1993	M
20482	11	Renato	Steffen	3	11	1991	M
75926	12	Jonas	Omlin	10	1	1994	M
32222	14	Michel	Aebischer	6	1	1997	M
11878	15	Djibril	Sow	6	2	1997	M
71875	16	Christian	Fassnacht	11	11	1993	M
85823	17	Ruben	Vargas	5	8	1998	M
56868	18	Eray	Cömert	4	2	1998	M
85577	19	Noah	Okafor	24	5	2000	M
244	20	Fabian	Frei	8	1	1989	M
6076	21	Gregor	Kobel	6	12	1997	M
38800	24	Philipp	Köhn	2	4	1998	M
25593	25	Fabian	Rieder	16	2	2002	M
17496	26	Ardon	Jashari	30	7	2002	M
22128	2	Bilel	Ifa	9	3	1990	M
73455	3	Montassar	Talbi	26	5	1998	M
68161	5	Nader	Ghandri	18	2	1995	M
25741	7	Youssef	Msakni	28	10	1990	M
48887	8	Hannibal	Mejbri	21	1	2003	M
11346	9	Issam	Jebali	25	12	1991	M
21865	11	Taha Yassine	Khenissi	6	1	1992	M
29063	14	Aïssa	Laïdouni	13	12	1996	M
42575	15	Mohamed Ali	Ben Romdhane	6	9	1999	M
32803	16	Aymen	Dahmen	28	1	1997	M
82056	19	Seifeddine	Jaziri	12	2	1993	M
49094	20	Mohamed	Dräger	25	6	1996	M
27079	21	Wajdi	Kechrida	5	11	1995	M
82657	22	Bechir	Ben Saïd	29	11	1992	M
64924	24	Ali	Abdi	20	12	1993	M
45680	25	Anis	Ben Slimane	16	3	2001	M
48903	1	Matt	Turner	24	6	1994	M
89452	2	Sergiño	Dest	3	11	2000	M
57029	3	Walker	Zimmerman	19	5	1993	M
14151	4	Tyler	Adams	14	2	1999	M
70867	5	Antonee	Robinson	8	8	1997	M
59571	6	Yunus	Musah	29	11	2002	M
85878	7	Giovanni	Reyna	13	11	2002	M
68952	8	Weston	McKennie	28	8	1998	M
34132	9	Jesús	Ferreira	24	12	2000	M
11737	10	Christian	Pulisic	18	9	1998	M
3484	11	Brenden	Aaronson	22	10	2000	M
1792	12	Ethan	Horvath	9	6	1995	M
26367	13	Tim	Ream	5	10	1987	M
74007	14	Luca	de la Torre	23	5	1998	M
75522	15	Aaron	Long	12	10	1992	M
77402	16	Jordan	Morris	26	10	1994	M
35320	17	Cristian	Roldan	3	6	1995	M
48265	18	Shaq	Moore	2	11	1996	M
68131	19	Haji	Wright	27	3	1998	M
25925	20	Cameron	Carter-Vickers	31	12	1997	M
30252	21	Timothy	Weah	22	2	2000	M
86410	23	Kellyn	Acosta	24	7	1995	M
94647	24	Josh	Sargent	20	2	2000	M
38940	25	Sean	Johnson	31	5	1989	M
80838	26	Joe	Scally	31	12	2002	M
89869	4	Ronald	Araújo	7	3	1999	M
86878	7	Nicolás	de la Cruz	1	6	1997	M
95062	8	Facundo	Pellistri	20	12	2001	M
18885	11	Darwin	Núñez	24	6	1999	M
19914	12	Sebastián	Sosa	19	8	1986	M
5174	15	Federico	Valverde	22	7	1998	M
90796	16	Mathías	Olivera	31	10	1997	M
18564	17	Matías	Viña	9	11	1997	M
68430	20	Facundo	Torres	13	4	2000	M
232	23	Sergio	Rochet	23	3	1993	M
24667	24	Agustín	Canobbio	1	10	1998	M
94091	25	Manuel	Ugarte	11	4	2001	M
55597	26	José Luis	Rodríguez	14	3	1997	M
46457	1	Wayne	Hennessey	24	1	1987	M
92343	2	Chris	Gunter	21	7	1989	M
87190	3	Neco	Williams	13	4	2001	M
41198	4	Ben	Davies	24	4	1993	M
74888	5	Chris	Mepham	5	11	1997	M
38105	6	Joe	Rodon	22	10	1997	M
92761	7	Joe	Allen	14	3	1990	M
94779	8	Harry	Wilson	22	3	1997	M
57098	9	Brennan	Johnson	23	5	2001	M
86951	10	Aaron	Ramsey	26	12	1990	M
63927	11	Gareth	Bale	16	7	1989	M
31718	12	Danny	Ward	22	6	1993	M
10657	13	Kieffer	Moore	8	8	1992	M
56503	14	Connor	Roberts	23	9	1995	M
50398	15	Ethan	Ampadu	14	9	2000	M
69082	16	Joe	Morrell	3	1	1997	M
34567	17	Tom	Lockyer	3	12	1994	M
56664	18	Jonny	Williams	9	10	1993	M
37173	19	Mark	Harris	29	12	1998	M
74707	20	Daniel	James	10	11	1997	M
92482	21	Adam	Davies	17	7	1992	M
20564	22	Sorba	Thomas	25	1	1999	M
24982	23	Dylan	Levitt	17	11	2000	M
2030	24	Ben	Cabango	30	5	2000	M
7137	25	Rubin	Colwill	27	4	2002	M
84269	26	Matthew	Smith	22	11	1999	M
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

