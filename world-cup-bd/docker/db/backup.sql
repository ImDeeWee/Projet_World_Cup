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
    'jaune',
    'rouge'
);


ALTER TYPE public.type_faute OWNER TO wcuser;

--
-- Name: type_rang; Type: TYPE; Schema: public; Owner: wcuser
--

CREATE TYPE public.type_rang AS ENUM (
    'phase de pool',
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
    nb_jaunes    INT;
    existe_rouge BOOLEAN;
BEGIN
    /* Y a-t-il déjà un rouge pour ce joueur dans ce match ? */
    SELECT EXISTS (
        SELECT 1
          FROM faute
         WHERE joueur_id = NEW.joueur_id
           AND match_id  = NEW.match_id
           AND typefaute = 'rouge'
    ) INTO existe_rouge;

    IF existe_rouge THEN
        RAISE EXCEPTION
          'Le joueur % a déjà un carton rouge pour le match %, insertion refusée',
          NEW.joueur_id, NEW.match_id;
    END IF;

    /* Si l’on ajoute un jaune, faut-il le transformer en rouge ? */
    IF NEW.typefaute = 'jaune' THEN
        SELECT COUNT(*)
          INTO nb_jaunes
          FROM faute
         WHERE joueur_id = NEW.joueur_id
           AND match_id  = NEW.match_id
           AND typefaute = 'jaune';

        IF nb_jaunes >= 1 THEN   -- c’est le 2ᵉ jaune
            NEW.typefaute := 'rouge';
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
BEGIN
    IF NEW.pointequipea > NEW.pointequipeb THEN
        UPDATE matchs 
        SET gagnant_id = (SELECT id_equipea FROM matchs WHERE id_match = NEW.match_id)
        WHERE id_match = NEW.match_id;
    ELSIF NEW.pointequipea < NEW.pointequipeb THEN
        UPDATE matchs 
        SET gagnant_id = (SELECT id_equipeb FROM matchs WHERE id_match = NEW.match_id)
        WHERE id_match = NEW.match_id;
    ELSIF NEW.pointequipea = NEW.pointequipeb THEN
        -- Vérifier les tirs au but si disponibles
        IF NEW.penaltie_equipea IS NOT NULL AND NEW.penaltie_equipeb IS NOT NULL THEN
            IF NEW.penaltie_equipea > NEW.penaltie_equipeb THEN
                UPDATE matchs 
                SET gagnant_id = (SELECT id_equipea FROM matchs WHERE id_match = NEW.match_id)
                WHERE id_match = NEW.match_id;
            ELSIF NEW.penaltie_equipea < NEW.penaltie_equipeb THEN
                UPDATE matchs 
                SET gagnant_id = (SELECT id_equipeb FROM matchs WHERE id_match = NEW.match_id)
                WHERE id_match = NEW.match_id;
            ELSE
                -- Cas rare : match nul après tirs au but
                UPDATE matchs 
                SET gagnant_id = NULL
                WHERE id_match = NEW.match_id;
            END IF;
        ELSE
            -- Pas de tirs au but, match nul
            UPDATE matchs 
            SET gagnant_id = NULL
            WHERE id_match = NEW.match_id;
        END IF;
    END IF;
    RETURN NEW;
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
-- Name: equipe; Type: TABLE; Schema: public; Owner: wcuser
--

CREATE TABLE public.equipe (
    nompays character varying(30) NOT NULL,
    anneecoupe integer NOT NULL,
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
    pointequipeb integer NOT NULL,
    penaltie_equipea integer,
    penaltie_equipeb integer
);


ALTER TABLE public.scorefinal OWNER TO wcuser;

--
-- Name: selectionneur; Type: TABLE; Schema: public; Owner: wcuser
--

CREATE TABLE public.selectionneur (
    id_staff integer NOT NULL,
    prenomstaff character varying(30),
    nomstaff character varying(30),
    id_equipe integer
);


ALTER TABLE public.selectionneur OWNER TO wcuser;

--
-- Name: stafftechnique_id_staff_seq; Type: SEQUENCE; Schema: public; Owner: wcuser
--

ALTER TABLE public.selectionneur ALTER COLUMN id_staff ADD GENERATED ALWAYS AS IDENTITY (
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
1	Principal	Thomas	Balvay
2	Principal	Henri	Christophe
3	Principal	Gilberto	de Almeida Rego
4	Principal	John	Langenus
5	Principal	Domingo	Lombardi
6	Principal	Jose	Macias
7	Principal	Francisco	Mateucci
8	Principal	Ulises	Saucedo
9	Principal	Anibal	Tejada
10	Principal	Ricardo	Vallarino
11	Principal	Alberto	Warnken
12	Principal	Louis	Baert
13	Principal	Rinaldo	Barlassina
14	Principal	Alois	Beranek
15	Principal	Alfred	Birlem
16	Principal	Eugen	Braun
17	Principal	Albino	Carraro
18	Principal	Ivan	Eklind
19	Principal	Francesco	Mattea
20	Principal	Rene	Mercet
21	Principal	Johannes	van Moorsel
22	Principal	Georges	Capdeville
23	Principal	Roger	Conrie
24	Principal	Augustin	Krist
25	Principal	Lucien	Leclerq
26	Principal	Giuseppe	Scarpi
27	Principal	Pal	von Hertzka
28	Principal	Hans	Wuthrich
29	Principal	Ramon	Azon Roma
30	Principal	Generoso	Dattilo
31	Principal	Arthur Edward	Ellis
32	Principal	Giovanni	Galeati
33	Principal	Mario	Gardelli
34	Principal	Sandy	Griffiths
35	Principal	Reginald	Leafe
36	Principal	Jean	Lutz
37	Principal	Alberto	Malcher
38	Principal	George	Mitchell
39	Principal	George	Reader
40	Principal	Karel	van der Meer
41	Principal	Mario	Vianna
42	Principal	Manuel	Asensi
43	Principal	Jose	da Costa Vieira
44	Principal	Charlie	Faultless
45	Principal	Laurent	Franken
46	Principal	William	Ling
47	Principal	Esteban	Marino
48	Principal	Vincenzo	Orlandini
49	Principal	Emil	Schmetzer
50	Principal	Vasa	Stefanovic
51	Principal	Carl Erich	Steiner
52	Principal	Raymond	Vincenti
53	Principal	Raymond	Wyssling
54	Principal	Istvan	Zsolt
55	Principal	Sten	Ahlner
56	Principal	Jan	Bronkhorst
57	Principal	Joaquim	Campos
58	Principal	Jose Maria	Codesal
59	Principal	Albert	Dusch
60	Principal	Arne	Eriksson
61	Principal	Juan	Garay Gardeazabal
62	Principal	Maurice	Guigue
63	Principal	Carl	Jrgensen
64	Principal	Leo	Lemesic
65	Principal	Nikolai	Levnikov
66	Principal	Martin	Macko
67	Principal	Jack	Mowat
68	Principal	Juan	Regis Brozzi
69	Principal	Fritz	Seipelt
70	Principal	Lucien	van Nuffel
71	Principal	Kenneth	Aston
72	Principal	Antoine	Blavier
73	Principal	Sergio	Bustamante
74	Principal	Bobby	Davidson
75	Principal	Gottfried	Dienst
76	Principal	Andor	Dorogi
77	Principal	Joao	Etzel Filho
78	Principal	Karol	Galba
79	Principal	Leo	Horn
80	Principal	Cesare	Jonni
81	Principal	Carlos	Robles
82	Principal	Pierre	Schwinte
83	Principal	Branko	Tesanic
84	Principal	Arturo	Yamasaki Maldonado
85	Principal	John	Adair
86	Principal	Menachem	Ashkenazi
87	Principal	Tofiq	Bahramov
88	Principal	Leo	Callaghan
89	Principal	Ken	Dagnall
90	Principal	Jim	Finney
91	Principal	Roberto	Goicoechea
92	Principal	Ali	Kandil
93	Principal	Rudolf	Kreitlein
94	Principal	Concetto	Lo Bello
95	Principal	Bertil	Loow
96	Principal	Armando	Marques
97	Principal	George	McCabe
98	Principal	Hugh	Phillips
99	Principal	Dimitar	Rumenchev
100	Principal	Kurt	Tschenscher
101	Principal	Konstantin	Zecevic
102	Principal	Abel	Aguilar Elizalde
103	Principal	Ramon	Barreto Ruiz
104	Principal	Diego	De Leo
105	Principal	Rudi	Glockner
106	Principal	Rafael	Hormazabal Diaz
107	Principal	Abraham	Klein
108	Principal	Henry	Landauer
109	Principal	Vital	Loraux
110	Principal	Roger	Machin
111	Principal	Ferdinand	Marschall
112	Principal	Angel	Norberto Coerezza
113	Principal	Jose Maria	Ortiz de Mendibil
114	Principal	Andrei	Radulescu
115	Principal	Antonio	Ribeiro Saldanha
116	Principal	Antonio	Sbardella
117	Principal	Rudolf	Scheurer
118	Principal	Seyoum	Tarekegn
119	Principal	Jack	Taylor
120	Principal	Laurens	van Ravens
121	Principal	Ayrton	Vieira de Moraes
122	Principal	Aurelio	Angonese
123	Principal	Dogan	Babacan
124	Principal	Tony	Boskovic
125	Principal	Omar	Delgado Gomez
126	Principal	Alfonso	Gonzalez Archundia
127	Principal	Pavel	Kazakov
128	Principal	Erich	Linemayr
129	Principal	Vicente	Llobregat
130	Principal	Mahmoud	Mustafa Kamel
131	Principal	Youssou	N'Diaye
132	Principal	Jafar	Namdar
133	Principal	Karoly	Palotai
134	Principal	Edison	Perez Nunez
135	Principal	Luis	Pestarino
136	Principal	Nicolae	Rainea
137	Principal	Pablo	Sanchez Ibanez
138	Principal	Gerhard	Schulenburg
139	Principal	Govindasamy	Suppiah
140	Principal	Clive	Thomas
141	Principal	Arie	van Gemert
142	Principal	Hans-Joachim	Weyland
143	Principal	Werner	Winsemann
144	Principal	Ferdinand	Biwersi
145	Principal	Farouk	Bouzo
146	Principal	Arnaldo Cezar	Coelho
147	Principal	Charles	Corver
148	Principal	Jean	Dubach
149	Principal	Ulf	Eriksson
150	Principal	Antonio	Garrido
151	Principal	Sergio	Gonella
152	Principal	John	Gordon
153	Principal	Cesar	Guerrero Orosco
154	Principal	Alojzy	Jarguz
155	Principal	Dusan	Maksimovic
156	Principal	Angel Franco	Martinez
157	Principal	Pat	Partridge
158	Principal	Adolf	Prokop
159	Principal	Francis	Rion
160	Principal	Juan	Silvagno Cavanna
161	Principal	Robert	Wurtz
162	Principal	Ibrahim Youssef	Al-Doy
163	Principal	Yousef	Alghoul
164	Principal	Gilberto	Aristizabal
165	Principal	Luis	Barrancos
166	Principal	Juan Daniel	Cardellino
167	Principal	Paolo	Casarin
168	Principal	Gaston	Castro
169	Principal	Tam Sun	Chan
170	Principal	Vojtech	Christov
171	Principal	Bogdan	Dotchev
172	Principal	Benjamin	Dwomoh
173	Principal	Walter	Eschweiler
174	Principal	Erik	Fredriksson
175	Principal	Bruno	Galler
176	Principal	Arturo	Ithurralde
177	Principal	Enrique	Labo Revoredo
178	Principal	Belaid	Lacarne
179	Principal	Augusto	Lamo Castillo
180	Principal	Henning	Lund-Srensen
181	Principal	Damir	Matovinovic
182	Principal	Romulo	Mendez
183	Principal	Malcolm	Moffat
184	Principal	Hector	Ortiz
185	Principal	Luis	Paulino Siles
186	Principal	Alexis	Ponnet
187	Principal	David	Socha
188	Principal	Myroslav	Stupar
189	Principal	Bob	Valentine
190	Principal	Michel	Vautrot
191	Principal	Mario Rubio	Vazquez
192	Principal	Clive	White
193	Principal	Franz	Wohrer
194	Principal	Luigi	Agnolin
195	Principal	Fallaj	Al-Shanar
196	Principal	Jamal	Al-Sharif
197	Principal	Romualdo	Arppi Filho
198	Principal	Chris	Bambridge
199	Principal	Ali	Bin Nasser
200	Principal	Horst	Brummeier
201	Principal	Valeri	Butenko
202	Principal	George	Courtney
203	Principal	Andre	Daina
204	Principal	Jesus	Diaz
205	Principal	Carlos	Esposito
206	Principal	Gabriel	Gonzalez
207	Principal	Ioan	Igna
208	Principal	Jan	Keizer
209	Principal	Siegfried	Kirschen
210	Principal	Antonio	Marquez Ramirez
211	Principal	Jose Luis	Martinez Bazan
212	Principal	Lajos	Nemeth
213	Principal	Zoran	Petrovic
214	Principal	Edwin	Picon-Ackong
215	Principal	Joel	Quiniou
216	Principal	Volker	Roth
217	Principal	Victoriano	Sanchez Arminio
218	Principal	Hernan	Silva
219	Principal	Carlos	Silva Valente
220	Principal	Alan	Snoddy
221	Principal	Shizuo	Takada
222	Principal	Idrissa	Traore
223	Principal	Berny	Ulloa Morera
224	Principal	Edgardo	Codesal
225	Principal	Elias	Jacome
226	Principal	Neji	Jouini
227	Principal	Helmut	Kohl
228	Principal	Tullio	Lanese
229	Principal	Juan Carlos	Loustau
230	Principal	Carlos	Maciel
231	Principal	Vincent	Mauro
232	Principal	Peter	Mikkelsen
233	Principal	Kurt	Rothlisberger
234	Principal	Aron	Schmidhuber
235	Principal	George	Smith
236	Principal	Emilio	Soriano Aladren
237	Principal	Alexey	Spirin
238	Principal	Marcel	van Langenhove
239	Principal	Jose Roberto	Wright
240	Principal	Fethi	Boucetta
241	Principal	Salvador	Imperatore
242	Principal	Jun	Lu
243	Principal	Jim	McCluskey
244	Principal	Vassilios	Nikakis
245	Principal	Rafael	Rodriguez Medina
246	Principal	Gyanu Raja	Shrestha
247	Principal	John	Toro Rendon
248	Principal	Claudia	Vasconcelos
249	Principal	Omer	Yengo
250	Principal	Vadim	Zhuk
251	Principal	Arturo	Angeles
252	Principal	Rodrigo	Badilla
253	Principal	Fabio	Baldas
254	Principal	Arturo	Brizio Carter
255	Principal	Ali	Bujsaim
256	Principal	Filippi	Cavani
257	Principal	Manuel	Diaz Vega
258	Principal	Philip	Don
259	Principal	Bo	Karlsson
260	Principal	Hellmut	Krug
261	Principal	Francisco Oscar	Lamolina
262	Principal	Kee Chong	Lim
263	Principal	Renato	Marsiglia
264	Principal	Leslie	Mottram
265	Principal	Pierluigi	Pairetto
266	Principal	Sandor	Puhl
267	Principal	Alberto	Tejada Noriega
268	Principal	Jose	Torres Cadena
269	Principal	Mario	van der Ende
270	Principal	Linda May	Black
271	Principal	Engage	Camara
272	Principal	Sonia	Denoncourt
273	Principal	Eduardo	Gamboa
274	Principal	Alain	Hamer
275	Principal	Catherine Leann	Hepburn
276	Principal	Ingrid	Jonsson
277	Principal	Petros	Mathabela
278	Principal	Eva	Odlund
279	Principal	Maria Edilene	Siqueira
280	Principal	Bente	Skogvang
281	Principal	Pirom	Un-prasert
282	Principal	Gamal	Al-Ghandour
283	Principal	Esfandiar	Baharmast
284	Principal	Marc	Batta
285	Principal	Said	Belqola
286	Principal	Gunter	Benko
287	Principal	Lucien	Bouchardeau
288	Principal	Javier	Castrilli
289	Principal	Pierluigi	Collina
290	Principal	Hugh	Dallas
291	Principal	Paul	Durkin
292	Principal	Jose Maria	Garcia-Aranda
293	Principal	Epifanio	Gonzalez
294	Principal	Bernd	Heynemann
295	Principal	Eddie	Lennie
296	Principal	Ian	McLeod
297	Principal	Urs	Meier
298	Principal	Vitor	Melo Pereira
299	Principal	Kim Milton	Nielsen
300	Principal	Masayoshi	Okada
301	Principal	Rune	Pedersen
302	Principal	Abdul	Rahman Al-Zeid
303	Principal	Ramesh	Ramdhan
304	Principal	Marcio	Rezende de Freitas
305	Principal	Mario	Sanchez Yanten
306	Principal	Laszlo	Vagner
307	Principal	Ryszard	Wojcik
308	Principal	Bola Elizabeth	Abidoye
309	Principal	Marisela	Contreras
310	Principal	Katriina	Elovirta
311	Principal	Fatou	Gaye
312	Principal	Elke	Gunthner
313	Principal	Sandra	Hunt
314	Principal	Eun-ju	Im
315	Principal	Gitte	Nielsen
316	Principal	Tammy	Ogston
317	Principal	Martha Liliana	Pardo
318	Principal	Nicole	Petignat
319	Principal	Kari	Seitz
320	Principal	Virginia	Tovar
321	Principal	Xiudi	Zuo
322	Principal	Ubaldo	Aquino
323	Principal	Carlos Alberto	Batres
324	Principal	Coffi	Codjia
325	Principal	Mourad	Daami
326	Principal	Anders	Frisk
327	Principal	Mohamed	Guezzaz
328	Principal	Brian	Hall
329	Principal	Terje	Hauge
330	Principal	Toru	Kamikawa
331	Principal	Young-joo	Kim
332	Principal	Antonio	Lopez Nieto
333	Principal	Saad	Mane
334	Principal	William	Mattus
335	Principal	Markus	Merk
336	Principal	Lubos	Michel
337	Principal	Byron	Moreno
338	Principal	Falla	N'Doye
339	Principal	Rene	Ortube
340	Principal	Graham	Poll
341	Principal	Peter	Prendergast
342	Principal	Felipe	Ramos
343	Principal	Oscar	Ruiz
344	Principal	Angel	Sanchez
345	Principal	Mark	Shield
346	Principal	Carlos Eugenio	Simon
347	Principal	Kyros	Vassaras
348	Principal	Gilles	Veissiere
349	Principal	Jan	Wegereef
350	Principal	Xonam	Agboyi
351	Principal	Cristina	Ionescu
352	Principal	Florencia	Romano
353	Principal	Sueli	Tortura
354	Principal	Dongqing	Zhang
355	Principal	Essam	Abdel-Fatah
356	Principal	Carlos	Amarilla
357	Principal	Benito	Archundia
358	Principal	Massimo	Busacca
359	Principal	Frank	De Bleeckere
360	Principal	Horacio	Elizondo
361	Principal	Valentin	Ivanov
362	Principal	Jorge	Larrionda
363	Principal	Shamsul	Maidin
364	Principal	Luis	Medina Cantalejo
365	Principal	Eric	Poulat
366	Principal	Marco Antonio	Rodriguez
367	Principal	Roberto	Rosetti
368	Principal	Christine	Beck
369	Principal	Jennifer	Bennett
370	Principal	Adriana	Correa
371	Principal	Dagmar	Damkova
372	Principal	Dianne	Ferreira-James
373	Principal	Gyongyi	Gaal
374	Principal	Pannipar	Kamnueng
375	Principal	Huijun	Niu
376	Principal	Mayumi	Oiwa
377	Principal	Jenny	Palmqvist
378	Principal	Khalil	Al-Ghamdi
379	Principal	Hector	Baldassi
380	Principal	Olegario	Benquerenca
381	Principal	Koman	Coulibaly
382	Principal	Jerome	Damon
383	Principal	Michael	Hester
384	Principal	Ravshan	Irmatov
385	Principal	Viktor	Kassai
386	Principal	Stephane	Lannoy
387	Principal	Eddy	Maillet
388	Principal	Yuichi	Nishimura
389	Principal	Pablo	Pozo
390	Principal	Wolfgang	Stark
391	Principal	Alberto	Undiano Mallenco
392	Principal	Howard	Webb
393	Principal	Quetzalli	Alvarado
394	Principal	Estela	Alvarez
395	Principal	Sung-mi	Cha
396	Principal	Carol Anne	Chenard
397	Principal	Etsuko	Fukano
398	Principal	Kirsi	Heikkinen
399	Principal	Jacqui	Melksham
400	Principal	Therese	Neguel
401	Principal	Christina	Pedersen
402	Principal	Silvia	Reyes
403	Principal	Bibiana	Steinhaus
404	Principal	Finau	Vulivuli
405	Principal	Joel	Aguilar
406	Principal	Felix	Brych
407	Principal	Cuneyt	Cakr
408	Principal	Noumandiez	Doue
409	Principal	Jonas	Eriksson
410	Principal	Bakary	Gassama
411	Principal	Mark	Geiger
412	Principal	Djamel	Haimoudi
413	Principal	Bjorn	Kuipers
414	Principal	Milorad	Mazic
415	Principal	Peter	O'Leary
416	Principal	Enrique	Osses
417	Principal	Nestor	Pitana
418	Principal	Pedro	Proenca
419	Principal	Sandro	Ricci
420	Principal	Nicola	Rizzoli
421	Principal	Wilmar	Roldan
422	Principal	Nawaf	Shukralla
423	Principal	Carlos	Velasco Carballo
424	Principal	Carlos	Vera
425	Principal	Ben	Williams
426	Principal	Teodora	Albon
427	Principal	Melissa	Borjas
428	Principal	Salome	di Iorio
429	Principal	Margaret	Domka
430	Principal	Stephanie	Frappart
431	Principal	Rita	Gani
432	Principal	Anna-Marie	Keighley
433	Principal	Katalin	Kulcsar
434	Principal	Pernilla	Larsson
435	Principal	Gladys	Lengwe
436	Principal	Yeimy	Martinez
437	Principal	Efthalia	Mitsi
438	Principal	Kateryna	Monzul
439	Principal	Liang	Qin
440	Principal	Hyang-ok	Ri
441	Principal	Esther	Staubli
442	Principal	Claudia	Umpierrez
443	Principal	Lucila	Venegas
444	Principal	Carina	Vitulano
445	Principal	Sachiko	Yamagishi
446	Principal	Enrique	Caceres
447	Principal	Matthew	Conger
448	Principal	Andres	Cunha
449	Principal	Malang	Diedhiou
450	Principal	Alireza	Faghani
451	Principal	Gehad	Grisha
452	Principal	Mohammed Abdulla	Hassan Mohamed
453	Principal	Sergei	Karasev
454	Principal	Szymon	Marciniak
455	Principal	Jair	Marrufo
456	Principal	Antonio	Mateu Lahoz
457	Principal	Cesar Arturo	Ramos
458	Principal	Gianluca	Rocchi
459	Principal	Janny	Sikazwe
460	Principal	Damir	Skomina
461	Principal	Clement	Turpin
462	Principal	Jana	Adamkova
463	Principal	Edina	Alves Batista
464	Principal	Marie-Soleil	Beaudoin
465	Principal	Sandra	Braz
466	Principal	Maria	Carvajal
467	Principal	Laura	Fortunato
468	Principal	Riem	Hussein
469	Principal	Kate	Jacewicz
470	Principal	Salima	Mukansanga
471	Principal	Anastasia	Pustovoitova
472	Principal	Casey	Reibelt
473	Principal	Lidya	Tafesse
474	Principal	Yoshimi	Yamashita
475	Principal	Abdulrahman	Al-Jassim
476	Principal	Ivan	Barton
477	Principal	Chris	Beath
478	Principal	Raphael	Claus
479	Principal	Ismail	Elfath
480	Principal	Mario	Escobar
481	Principal	Mustapha	Ghorbal
482	Principal	Victor	Gomes
483	Principal	Danny	Makkelie
484	Principal	Andres	Matonte
485	Principal	Michael	Oliver
486	Principal	Daniele	Orsato
487	Principal	Fernando	Rapallini
488	Principal	Wilton	Sampaio
489	Principal	Daniel	Siebert
490	Principal	Anthony	Taylor
491	Principal	Facundo	Tello
492	Principal	Jesus	Valenzuela
493	Principal	Slavko	Vincic
494	Assistant	Joshua	Vargas
495	Assistant	Samuel	Richardson
496	Assistant	Stacey	Johnson
497	Assistant	Troy	King
498	Assistant	Elizabeth	Cook
499	Assistant	Joshua	Abbott
500	Assistant	Daniel	Hunter
501	Assistant	Anthony	Pugh
502	Assistant	Nancy	King
503	Assistant	Elizabeth	Gonzales
504	Assistant	Michael	Jones
505	Assistant	Ernest	Roberts
506	Assistant	Melvin	Carroll
507	Assistant	Matthew	Freeman
508	Assistant	Christopher	Valentine
509	Assistant	Charles	Cunningham
510	Assistant	Jason	Larson
511	Assistant	Brian	Forbes
512	Assistant	Elizabeth	Jones
513	Assistant	Shawn	Dean
514	Assistant	Desiree	Jackson
515	Assistant	Charles	Castillo
516	Assistant	Roberto	Stewart
517	Assistant	Brian	Ayala
518	Assistant	Carla	Haney
519	Assistant	Amanda	Cox
520	Assistant	Robert	Guerrero
521	Assistant	Robert	Edwards
522	Assistant	Susan	Bryant
523	Assistant	Bradley	Rodriguez
524	Assistant	Ann	Allen
525	Assistant	John	Moran
526	Assistant	Christopher	Ramos
527	Assistant	Paul	Jackson
528	Assistant	Katelyn	Vazquez
529	Assistant	Timothy	Webb
530	Assistant	Adam	Hood
531	Assistant	Jennifer	Espinoza
532	Assistant	Benjamin	Griffin
533	Assistant	Stephen	Nichols
534	Assistant	Daisy	Horn
535	Assistant	Christie	Cohen
536	Assistant	Theresa	Burns
537	Assistant	Felicia	Bates
538	Assistant	Sheri	Hanson
539	Assistant	Brenda	Hunter
540	Assistant	Regina	Davis
541	Assistant	Victoria	Bennett
542	Assistant	Karen	Allen
543	Assistant	Sarah	Greer
544	Assistant	Carmen	Cook
545	Assistant	Michael	Simmons
546	Assistant	Wendy	Lutz
547	Assistant	Robert	Bailey
548	Assistant	Joshua	Moss
549	Assistant	Jennifer	Peters
550	Assistant	David	Weaver
551	Assistant	Donald	Ruiz
552	Assistant	Michael	Parks
553	Assistant	Spencer	Wiley
554	Assistant	Daniel	Johnson
555	Assistant	Kevin	Odonnell
556	Assistant	David	Downs
557	Assistant	Karina	Ball
558	Assistant	Sara	Thomas
559	Assistant	Ronald	Howard
560	Assistant	Robert	White
561	Assistant	Melissa	Warren
562	Assistant	Brenda	Morgan
563	Assistant	Gina	Morton
564	Assistant	Christopher	Coffey
565	Assistant	Amber	Young
566	Assistant	Courtney	Rodriguez
567	Assistant	Alex	Crawford
568	Assistant	Michael	Horton
569	Assistant	Vernon	Clark
570	Assistant	Lee	Howell
571	Assistant	Jillian	Parker
572	Assistant	Ashley	Thompson
573	Assistant	Angela	Ruiz
574	Assistant	Andrew	Franco
575	Assistant	Paul	Walker
576	Assistant	Jennifer	Adams
577	Assistant	Angela	Reyes
578	Assistant	Maria	Wilson
579	Assistant	Ryan	Wang
580	Assistant	Travis	Miles
581	Assistant	Karla	Schwartz
582	Assistant	Anthony	Williams
583	Assistant	Melanie	Castillo
584	Assistant	Richard	Hall
585	Assistant	Sean	Harrell
586	Assistant	Matthew	Howard
587	Assistant	Andrew	Atkinson
588	Assistant	Patricia	Haynes
589	Assistant	Donald	Byrd
590	Assistant	Allison	Cochran
591	Assistant	Tony	Banks
592	Assistant	Nathaniel	Morrison
593	Assistant	William	Gilbert
594	Assistant	Devin	Davis
595	Assistant	Nicole	Pittman
596	Assistant	Dan	Boyd
597	Assistant	Brian	Garcia
598	Assistant	Christine	Thompson
599	Assistant	Mary	Hines
600	Assistant	Peter	Ray
601	Assistant	Mario	Delgado
602	Assistant	Christopher	Werner
603	Assistant	Sabrina	Rodriguez
604	Assistant	Jasmine	Osborne
605	Assistant	Randy	Wilkinson
606	Assistant	Victoria	Long
607	Assistant	Danielle	Vasquez
608	Assistant	Patricia	Singleton
609	Assistant	Kristen	Foster
610	Assistant	Kevin	Garza
611	Assistant	Sheri	Villarreal
612	Assistant	Raymond	Hill
613	Assistant	Derrick	Nichols
614	Assistant	Gordon	Doyle
615	Assistant	Daniel	Flores
616	Assistant	John	Hester
617	Assistant	Joe	Fox
618	Assistant	Douglas	Wade
619	Assistant	Rachel	Reyes
620	Assistant	Gregory	Carter
621	Assistant	Shelly	Sanchez
622	Assistant	Steven	Finley
623	Assistant	Mary	Hoover
624	Assistant	Maxwell	Escobar
625	Assistant	Jeanne	Hernandez
626	Assistant	Erica	Diaz
627	Assistant	Rachael	Gonzalez
628	Assistant	Wendy	Rose
629	Assistant	Kathy	Johnson
630	Assistant	Terry	Lewis
631	Assistant	Brett	Stewart
632	Assistant	Elizabeth	Robinson
633	Assistant	David	Shah
634	Assistant	Sarah	Collier
635	Assistant	Jessica	Sawyer
636	Assistant	William	Ball
637	Assistant	Curtis	Crawford
638	Assistant	Michael	Kelly
639	Assistant	Shannon	Pope
640	Assistant	Robert	Gonzales
641	Assistant	Natalie	Brown
642	Assistant	Willie	Boyd
643	Assistant	Anthony	Love
644	Assistant	Robert	Leblanc
645	Assistant	Jared	Avila
646	Assistant	Ashley	Mcconnell
647	Assistant	Philip	Douglas
648	Assistant	Marie	Burton
649	Assistant	Angela	Perkins
650	Assistant	Michael	Edwards
651	Assistant	Nicolas	Holland
652	Assistant	April	Medina
653	Assistant	Wayne	Campbell
654	Assistant	Richard	Gray
655	Assistant	Mitchell	Lee
656	Assistant	Brad	Chang
657	Assistant	Courtney	Ward
658	Assistant	Debra	Holt
659	Assistant	Clayton	Rivera
660	Assistant	Jennifer	White
661	Assistant	Michael	Snyder
662	Assistant	Kimberly	Wolfe
663	Assistant	Nancy	Stephens
664	Assistant	Cynthia	Hernandez
665	Assistant	Jennifer	Robinson
666	Assistant	Kathryn	Flores
667	Assistant	Megan	Lowery
668	Assistant	Angela	Kelley
669	Assistant	Patricia	Taylor
670	Assistant	Heather	Hill
671	Assistant	Laurie	Turner
672	Assistant	Alan	Rodriguez
673	Assistant	Thomas	Merritt
674	Assistant	Jill	Rodriguez
675	Assistant	Jacob	Mendoza
676	Assistant	John	Spencer
677	Assistant	Jared	Long
678	Assistant	Michele	Miller
679	Assistant	Cheryl	Spence
680	Assistant	Billy	Foster
681	Assistant	Bradley	Johnson
682	Assistant	Derek	Combs
683	Assistant	Alex	Cole
684	Assistant	Christian	Young
685	Assistant	Christina	Mccoy
686	Assistant	April	Burnett
687	Assistant	Stephen	Garcia
688	Assistant	Chris	Bradford
689	Assistant	Ronald	Davis
690	Assistant	Robert	Moran
691	Assistant	Matthew	Durham
692	Assistant	Jason	Ramirez
693	Assistant	Barbara	Higgins
694	Assistant	Timothy	Pham
695	Assistant	Todd	Clark
696	Assistant	Christopher	Hale
697	Assistant	Alicia	Christensen
698	Assistant	Joseph	Rodriguez
699	Assistant	Mark	Jones
700	Assistant	Larry	Bender
701	Assistant	Melissa	Bush
702	Assistant	Melissa	Gamble
703	Assistant	Brian	Murphy
704	Assistant	Russell	Butler
705	Assistant	Richard	Dunn
706	Assistant	Richard	Boyd
707	Assistant	Bruce	Oneal
708	Assistant	Richard	Bennett
709	Assistant	Dan	Middleton
710	Assistant	Troy	Moore
711	Assistant	Michelle	Castro
712	Assistant	Katie	Rowland
713	Assistant	Thomas	Stone
714	Assistant	Gerald	Adams
715	Assistant	Russell	Lopez
716	Assistant	Renee	Reeves
717	Assistant	Vincent	Best
718	Assistant	Linda	Santos
719	Assistant	Shelley	Smith
720	Assistant	Courtney	Kennedy
721	Assistant	Christine	Wright
722	Assistant	Christopher	Patel
723	Assistant	Tracey	Clark
724	Assistant	Daniel	Hayes
725	Assistant	Krista	Kelly
726	Assistant	Beth	Owen
727	Assistant	Joshua	Collins
728	Assistant	Kimberly	Daniels
729	Assistant	Richard	Campbell
730	Assistant	Joshua	Berger
731	Assistant	Monica	Martin
732	Assistant	Joshua	Carter
733	Assistant	Stephanie	Bennett
734	Assistant	Bryan	Moore
735	Assistant	Larry	Wood
736	Assistant	Nicole	Gomez
737	Assistant	Madison	Obrien
738	Assistant	Tiffany	Martin
739	Assistant	Frank	Simpson
740	Assistant	Angela	Simmons
741	Assistant	Catherine	Tran
742	Assistant	Lee	Thomas
743	Assistant	Brittany	Yang
744	Assistant	Sheri	Perkins
745	Assistant	Andrea	Williams
746	Assistant	Laura	Ramos
747	Assistant	Jill	Gibbs
748	Assistant	Michael	Arias
749	Assistant	Jeff	Franklin
750	Assistant	William	Curry
751	Assistant	Christopher	Neal
752	Assistant	Ashley	Bowman
753	Assistant	Donna	Sanchez
754	Assistant	Jason	Smith
755	Assistant	Thomas	Gonzalez
756	Assistant	Candace	Gray
757	Assistant	Valerie	Cole
758	Assistant	Debra	Smith
759	Assistant	Pamela	Jones
760	Assistant	Tara	Cantu
761	Assistant	Justin	Wilson
762	Assistant	Melody	Ferrell
763	Assistant	Connor	Barron
764	Assistant	Cheyenne	Hill
765	Assistant	Curtis	Mayer
766	Assistant	Joshua	Medina
767	Assistant	Tina	Rodriguez
768	Assistant	Richard	Mckinney
769	Assistant	Mason	Ross
770	Assistant	Sarah	Coleman
771	Assistant	Robert	Gonzalez
772	Assistant	Pamela	Reilly
773	Assistant	Anthony	David
774	Assistant	Wanda	Sullivan
775	Assistant	Samantha	Mcclure
776	Assistant	David	Cook
777	Assistant	Lauren	Harvey
778	Assistant	Kelly	Murray
779	Assistant	Laura	Dennis
780	Assistant	Christopher	Ramos
781	Assistant	Chris	Little
782	Assistant	Zachary	Copeland
783	Assistant	Maria	Green
784	Assistant	Angela	Logan
785	Assistant	Brittany	Cummings
786	Assistant	Ethan	Ray
787	Assistant	Shelley	Rodriguez
788	Assistant	Brent	Burke
789	Assistant	Stacy	King
790	Assistant	Dawn	Gilbert
791	Assistant	Daniel	Harding
792	Assistant	Diamond	Thomas
793	Assistant	Nicholas	Carter
794	Assistant	Jennifer	Soto
795	Assistant	Katie	Kim
796	Assistant	Erik	Anderson
797	Assistant	Richard	Matthews
798	Assistant	Joy	Spence
799	Assistant	Michael	Smith
800	Assistant	Emily	Terry
801	Assistant	Billy	Lee
802	Assistant	Kaylee	Harris
803	Assistant	Shelby	Washington
804	Assistant	Devin	Haynes
805	Assistant	Teresa	Wright
806	Assistant	Raymond	Jimenez
807	Assistant	Terri	Thomas
808	Assistant	Alicia	Abbott
809	Assistant	Dorothy	Ochoa
810	Assistant	Elizabeth	Rich
811	Assistant	Michael	Douglas
812	Assistant	Jennifer	Smith
813	Assistant	Lisa	Mcneil
814	Assistant	William	Carter
815	Assistant	Benjamin	Bradley
816	Assistant	Benjamin	Armstrong
817	Assistant	Sara	Cook
818	Assistant	Helen	Pierce
819	Assistant	Carolyn	Williams
820	Assistant	Melanie	Chambers
821	Assistant	Anthony	Peterson
822	Assistant	Audrey	Curry
823	Assistant	William	Thompson
824	Assistant	Ashley	Lara
825	Assistant	Jessica	Sanchez
826	Assistant	Michael	Ferguson
827	Assistant	Sarah	Kaiser
828	Assistant	Joe	Gibbs
829	Assistant	Mark	Stephens
830	Assistant	Andrea	Sawyer
831	Assistant	Maria	Grant
832	Assistant	Chad	Marshall
833	Assistant	Jessica	Montoya
834	Assistant	Ashley	Gomez
835	Assistant	Christopher	Johnson
836	Assistant	Rebecca	Douglas
837	Assistant	Sarah	Powell
838	Assistant	Paula	Mcintosh
839	Assistant	Kevin	Lopez
840	Assistant	Leah	Vargas
841	Assistant	Keith	Reynolds
842	Assistant	Reginald	Peters
843	Assistant	Samuel	Lawrence
844	Assistant	Robert	Thomas
845	Assistant	Adam	Washington
846	Assistant	Jeremiah	Vance
847	Assistant	Kathleen	Christensen
848	Assistant	Tiffany	Massey
849	Assistant	Charles	Skinner
850	Assistant	Carol	Ross
851	Assistant	Christina	Leonard
852	Assistant	Veronica	Chang
853	Assistant	Christopher	Johnson
854	Assistant	Suzanne	Bailey
855	Assistant	Guy	Diaz
856	Assistant	Julie	Ortiz
857	Assistant	Christopher	Schmidt
858	Assistant	Jacob	Vincent
859	Assistant	Jimmy	Ford
860	Assistant	Angela	Singh
861	Assistant	Jason	Tran
862	Assistant	Jason	Fox
863	Assistant	Justin	Watson
864	Assistant	Brian	Smith
865	Assistant	Matthew	Gregory
866	Assistant	Sara	Christensen
867	Assistant	Debra	Willis
868	Assistant	Chad	Mccarthy
869	Assistant	Susan	Douglas
870	Assistant	Sharon	Walker
871	Assistant	Chloe	David
872	Assistant	Jackson	Barber
873	Assistant	Maria	Phillips
874	Assistant	Suzanne	Bryan
875	Assistant	Christopher	Johnson
876	Assistant	Thomas	Strickland
877	Assistant	Rebecca	Brown
878	Assistant	Amy	Barnes
879	Assistant	Adam	Horton
880	Assistant	Melissa	Hunt
881	Assistant	Christina	Gay
882	Assistant	Stephen	Jackson
883	Assistant	Stephen	Dalton
884	Assistant	Melissa	Cole
885	Assistant	Eric	Bentley
886	Assistant	Jane	Patel
887	Assistant	Thomas	Davis
888	Assistant	Cameron	Flowers
889	Assistant	Kelly	Schwartz
890	Assistant	Veronica	Adams
891	Assistant	Abigail	Spencer
892	Assistant	Jacqueline	Smith
893	Assistant	Johnny	Jackson
894	Assistant	Larry	Nolan
895	Assistant	Robert	Jones
896	Assistant	Leslie	Bell
897	Assistant	Peter	Johnson
898	Assistant	Michael	Vasquez
899	Assistant	Jose	Martinez
900	Assistant	Donald	Harris
901	Assistant	Katherine	Brown
902	Assistant	Daniel	Rivera
903	Assistant	James	Harrell
904	Assistant	Monica	Davis
905	Assistant	Heather	Browning
906	Assistant	Jeremiah	Morris
907	Assistant	Melinda	Hill
908	Assistant	Shawn	Fleming
909	Assistant	Emily	Nichols
910	Assistant	Laura	Warren
911	Assistant	Mary	Smith
912	Assistant	Kathryn	Parker
913	Assistant	Abigail	Flores
914	Assistant	Kevin	Maynard
915	Assistant	Jeffrey	Carson
916	Assistant	Jennifer	Kim
917	Assistant	Hunter	Vargas
918	Assistant	Glenda	Payne
919	Assistant	Cindy	Rodriguez
920	Assistant	Christina	Thompson
921	Assistant	Kevin	Willis
922	Assistant	James	Butler
923	Assistant	Crystal	Kennedy
924	Assistant	Crystal	Hancock
925	Assistant	Melinda	Mcgrath
926	Assistant	Anthony	Garza
927	Assistant	Jennifer	Stokes
928	Assistant	James	Ruiz
929	Assistant	Sandra	Adams
930	Assistant	Michael	Thomas
931	Assistant	Kara	Ortiz
932	Assistant	Andrea	Wilkerson
933	Assistant	Jon	Santos
934	Assistant	Martin	Collins
935	Assistant	Amanda	Jones
936	Assistant	Christopher	Mckinney
937	Assistant	David	Conway
938	Assistant	Cynthia	Maldonado
939	Assistant	Daniel	Brown
940	Assistant	Tanner	Shields
941	Assistant	William	Moore
942	Assistant	Sydney	Lamb
943	Assistant	Jason	Mora
944	Assistant	Michelle	Flores
945	Assistant	Hannah	Garrett
946	Assistant	Carrie	Dean
947	Assistant	Phillip	Walters
948	Assistant	Cody	Campbell
949	Assistant	Paul	Bailey
950	Assistant	Cameron	Hernandez
951	Assistant	Julie	Powell
952	Assistant	Jeffrey	Allen
953	Assistant	Cheryl	Henderson
954	Assistant	Brian	Mitchell
955	Assistant	Benjamin	Smith
956	Assistant	George	Williams
957	Assistant	Nicholas	Lopez
958	Assistant	Mark	Hudson
959	Assistant	Kaitlyn	Jones
960	Assistant	Charles	Hernandez
961	Assistant	Thomas	Bowman
962	Assistant	Harold	Jackson
963	Assistant	Fred	Thomas
964	Assistant	Amy	Barker
965	Assistant	Kimberly	Williams
966	Assistant	Justin	Massey
967	Assistant	Alison	Scott
968	Assistant	Sara	Brown
969	Assistant	Joseph	Coleman
970	Assistant	Rachel	Miller
971	Assistant	Kristy	Fuller
972	Assistant	Bryan	Carroll
973	Assistant	Michael	Hamilton
974	Assistant	Lisa	Armstrong
975	Assistant	Michael	Barron
976	Assistant	Jonathan	Alvarado
977	Assistant	Jesus	Tapia
978	Assistant	Paul	Jones
979	Assistant	Elizabeth	White
980	Assistant	Lori	Harrell
981	Assistant	April	Baker
982	Assistant	Samuel	Moran
983	Assistant	John	Soto
984	Assistant	Mark	Smith
985	Assistant	Catherine	Roberson
986	Assistant	Joseph	Hamilton
987	Assistant	John	Newman
988	Assistant	Brian	Buckley
989	Assistant	Michelle	Farley
990	Assistant	Elizabeth	Taylor
991	Assistant	Katie	Morris
992	Assistant	Katherine	Woods
993	Assistant	Matthew	Hester
994	Assistant	Javier	Nelson
995	Assistant	Michael	Hanson
996	Assistant	Lisa	Brooks
997	Assistant	James	Williams
998	Assistant	Emily	Cox
999	Assistant	Nathan	Krueger
1000	Assistant	Matthew	Nelson
1001	Assistant	Debra	Hogan
1002	Assistant	Meghan	Terry
1003	Assistant	Hannah	Hanna
1004	Assistant	Kevin	Ware
1005	Assistant	Denise	Smith
1006	Assistant	Sarah	Payne
1007	Assistant	Alexander	Gomez
1008	Assistant	Brian	Merritt
1009	Assistant	Courtney	Barton
1010	Assistant	Amanda	Barber
1011	Assistant	Hector	Luna
1012	Assistant	Bradley	Kim
1013	Assistant	Melanie	Mooney
1014	Assistant	Sharon	Ross
1015	Assistant	Jesse	King
1016	Assistant	Andrea	Taylor
1017	Assistant	Denise	Padilla
1018	Assistant	Roberta	Lee
1019	Assistant	Larry	Garcia
1020	Assistant	Amanda	Wilson
1021	Assistant	Daniel	Smith
1022	Assistant	Rachel	Jones
1023	Assistant	David	Dudley
1024	Assistant	Stephanie	Potter
1025	Assistant	Christopher	Smith
1026	Assistant	Amy	White
1027	Assistant	Tiffany	Rocha
1028	Assistant	Michele	Matthews
1029	Assistant	Donna	Green
1030	Assistant	John	Wright
1031	Assistant	Caroline	Powell
1032	Assistant	Albert	Sheppard
1033	Assistant	Virginia	Dudley
1034	Assistant	Brittany	Stevens
1035	Assistant	Craig	Riley
1036	Assistant	Elizabeth	Byrd
1037	Assistant	Peter	Garcia
1038	Assistant	Jessica	Burns
1039	Assistant	Richard	Smith
1040	Assistant	Randy	Cervantes
1041	Assistant	Timothy	Mckee
1042	Assistant	Bruce	Nelson
1043	Assistant	William	Mejia
1044	Assistant	Timothy	Hughes
1045	Assistant	Casey	Mitchell
1046	Assistant	Sharon	Miller
1047	Assistant	Amanda	Sexton
1048	Assistant	Andrea	Bell
1049	Assistant	Nicole	Fox
1050	Assistant	Tom	Smith
1051	Assistant	Suzanne	Mitchell
1052	Assistant	Alyssa	Morris
1053	Assistant	Leslie	Stokes
1054	Assistant	Kimberly	Thompson
1055	Assistant	Donna	Woodward
1056	Assistant	Jonathan	Holloway
1057	Assistant	Dwayne	Little
1058	Assistant	Stephanie	Dunlap
1059	Assistant	Theresa	Stephenson
1060	Assistant	Allison	Harris
1061	Assistant	Crystal	Beltran
1062	Assistant	Melvin	Perez
1063	Assistant	Marissa	Brown
1064	Assistant	Brittany	Wells
1065	Assistant	Christopher	Olson
1066	Assistant	Benjamin	Moore
1067	Assistant	Jay	Edwards
1068	Assistant	Laura	Allen
1069	Assistant	Monica	Dixon
1070	Assistant	Rebecca	Weber
1071	Assistant	Jacqueline	Gilbert
1072	Assistant	Ronald	Hendricks
1073	Assistant	Stephanie	Ferguson
1074	Assistant	Katherine	Bradford
1075	Assistant	Sandra	Duncan
1076	Assistant	Kimberly	Reed
1077	Assistant	Emily	Stevenson
1078	Assistant	Jason	Taylor
1079	Assistant	Sarah	Cowan
1080	Assistant	Alexander	Cox
1081	Assistant	Brandy	Guerra
1082	Assistant	Dustin	Cobb
1083	Assistant	Ronald	Martinez
1084	Assistant	Karen	Carter
1085	Assistant	Denise	Cline
1086	Assistant	John	Madden
1087	Assistant	Katherine	Gould
1088	Assistant	Mark	Gonzalez
1089	Assistant	Michael	Lopez
1090	Assistant	Kelli	Hernandez
1091	Assistant	Bonnie	Wiley
1092	Assistant	Rebecca	Hall
1093	Assistant	Jared	Leblanc
1094	Assistant	Joshua	Torres
1095	Assistant	Erica	Snyder
1096	Assistant	Brian	Reid
1097	Assistant	Gregory	Kelly
1098	Assistant	Melissa	Armstrong
1099	Assistant	Gabrielle	Hooper
1100	Assistant	Billy	Price
1101	Assistant	Robert	Rose
1102	Assistant	Kathleen	Thomas
1103	Assistant	Cody	Wilson
1104	Assistant	Nicole	Carroll
1105	Assistant	Linda	Garcia
1106	Assistant	David	Morgan
1107	Assistant	Kayla	Moore
1108	Assistant	Tonya	Garcia
1109	Assistant	Patricia	Williams
1110	Assistant	Carolyn	Smith
1111	Assistant	Kevin	Moore
1112	Assistant	Amanda	Rivera
1113	Assistant	Marissa	Brown
1114	Assistant	Megan	Gibson
1115	Assistant	Steve	Mills
1116	Assistant	Nicholas	Ford
1117	Assistant	Jo	Franklin
1118	Assistant	Casey	Rodriguez
1119	Assistant	Chad	Diaz
1120	Assistant	William	Wells
1121	Assistant	Ryan	Kelly
1122	Assistant	Connie	Stout
1123	Assistant	David	Bush
1124	Assistant	Dennis	Wolf
1125	Assistant	Steve	George
1126	Assistant	Daniel	Lewis
1127	Assistant	Tim	Hicks
1128	Assistant	Juan	Mccoy
1129	Assistant	Crystal	George
1130	Assistant	Victoria	Martinez
1131	Assistant	Cheyenne	Odom
1132	Assistant	Erika	Meyers
1133	Assistant	Ryan	Rodgers
1134	Assistant	Brittney	Gonzales
1135	Assistant	Elizabeth	Nelson
1136	Assistant	Benjamin	Flores
1137	Assistant	Thomas	Wilson
1138	Assistant	Carla	Cole
1139	Assistant	Diane	Coleman
1140	Assistant	Dalton	Young
1141	Assistant	Nicholas	Ball
1142	Assistant	Tracy	Schmidt
1143	Assistant	Amanda	Shelton
1144	Assistant	Debra	Mcmillan
1145	Assistant	Mitchell	Walker
1146	Assistant	Susan	Riggs
1147	Assistant	Grace	Sullivan
1148	Assistant	Vanessa	Robbins
1149	Assistant	Ralph	Manning
1150	Assistant	Eric	Mitchell
1151	Assistant	Donna	Gallegos
1152	Assistant	Matthew	Vargas
1153	Assistant	Ronald	Orr
1154	Assistant	Linda	Ellis
1155	Assistant	Lee	Lee
1156	Assistant	David	Ward
1157	Assistant	Zachary	Green
1158	Assistant	Mason	Wilson
1159	Assistant	Craig	Evans
1160	Assistant	Bernard	Leach
1161	Assistant	Lisa	Pope
1162	Assistant	Michele	Davis
1163	Assistant	Joshua	Lewis
1164	Assistant	Richard	Anderson
1165	Assistant	Jessica	Stanley
1166	Assistant	Wendy	Landry
1167	Assistant	Kimberly	Bonilla
1168	Assistant	Jason	Diaz
1169	Assistant	Linda	Martin
1170	Assistant	Patricia	Chung
1171	Assistant	Nathan	Bowen
1172	Assistant	Juan	Cabrera
1173	Assistant	Nicole	Orr
1174	Assistant	Peter	Hunter
1175	Assistant	Christy	Delgado
1176	Assistant	Margaret	Anderson
1177	Assistant	Eric	Elliott
1178	Assistant	Ryan	Mays
1179	Assistant	Vanessa	Tran
1180	Assistant	Joshua	Watson
1181	Assistant	Michael	Lee
1182	Assistant	Kimberly	Johnson
1183	Assistant	Marie	Medina
1184	Assistant	Joshua	Morse
1185	Assistant	Kyle	Mendez
1186	Assistant	Jay	Solis
1187	Assistant	Michael	Frost
1188	Assistant	Justin	Phillips
1189	Assistant	Leslie	Compton
1190	Assistant	Dylan	Murphy
1191	Assistant	Joshua	Luna
1192	Assistant	Janet	Crawford
1193	Assistant	Rachel	Clay
1194	Assistant	Sandra	Young
1195	Assistant	Christopher	Hughes
1196	Assistant	Diana	Parker
1197	Assistant	Frank	Powell
1198	Assistant	Courtney	Wade
1199	Assistant	Nicole	Montoya
1200	Assistant	Danny	Boyd
1201	Assistant	Danielle	Rodriguez
1202	Assistant	Michelle	Cunningham
1203	Assistant	Alexis	Reed
1204	Assistant	Colleen	Rojas
1205	Assistant	Jessica	Powers
1206	Assistant	Anthony	Hopkins
1207	Assistant	Casey	Howard
1208	Assistant	Jessica	Larsen
1209	Assistant	Jessica	Phillips
1210	Assistant	Allison	Moore
1211	Assistant	Kayla	Larson
1212	Assistant	Jennifer	Sanchez
1213	Assistant	Theresa	Shaffer
1214	Assistant	Kevin	Taylor
1215	Assistant	Kimberly	Smith
1216	Assistant	David	Anderson
1217	Assistant	Stanley	Marks
1218	Assistant	Jill	Cline
1219	Assistant	David	Turner
1220	Assistant	Eric	Reed
1221	Assistant	Lindsey	Olson
1222	Assistant	Thomas	Meyers
1223	Assistant	Eugene	Reed
1224	Assistant	Heather	Chambers
1225	Assistant	Dawn	Griffin
1226	Assistant	Melinda	Young
1227	Assistant	Stephanie	Mendez
1228	Assistant	Francisco	Farley
1229	Assistant	Christopher	Smith
1230	Assistant	Bonnie	Marquez
1231	Assistant	Melinda	Cooper
1232	Assistant	Amy	Garcia
1233	Assistant	Shelia	Smith
1234	Assistant	Paula	Beck
1235	Assistant	Caitlin	Terrell
1236	Assistant	Casey	Ramirez
1237	Assistant	Christine	Cook
1238	Assistant	Mitchell	Smith
1239	Assistant	Glenn	Ward
1240	Assistant	Sara	Wilson
1241	Assistant	Cynthia	Kaiser
1242	Assistant	Felicia	Harris
1243	Assistant	Brittany	Williams
1244	Assistant	Michelle	Campbell
1245	Assistant	Jason	Goodwin
1246	Assistant	Courtney	Smith
1247	Assistant	Edwin	Weber
1248	Assistant	Taylor	Barker
1249	Assistant	Debra	Nunez
1250	Assistant	Jacob	Gonzalez
1251	Assistant	Jennifer	Bradford
1252	Assistant	Beth	Golden
1253	Assistant	David	Dawson
1254	Assistant	Walter	Hughes
1255	Assistant	John	Mack
1256	Assistant	Joshua	Welch
1257	Assistant	Kimberly	Rogers
1258	Assistant	Nathan	Clark
1259	Assistant	Kyle	Munoz
1260	Assistant	Anthony	Collins
1261	Assistant	Anthony	Stewart
1262	Assistant	Scott	Vazquez
1263	Assistant	Tina	Nguyen
1264	Assistant	James	Sanchez
1265	Assistant	Bruce	Wilson
1266	Assistant	David	Taylor
1267	Assistant	Paul	Stone
1268	Assistant	Mark	Hudson
1269	Assistant	Briana	Patterson
1270	Assistant	Shari	Perez
1271	Assistant	David	Huerta
1272	Assistant	Sarah	Nixon
1273	Assistant	Matthew	Johnson
1274	Assistant	Lori	Peterson
1275	Assistant	Daniel	Hansen
1276	Assistant	Christopher	Francis
1277	Assistant	Kyle	Craig
1278	Assistant	Megan	Davis
1279	Assistant	Diana	Anderson
1280	Assistant	Emily	Oliver
1281	Assistant	Lisa	Hogan
1282	Assistant	Alexander	Gonzales
1283	Assistant	Timothy	Adams
1284	Assistant	Jessica	Christian
1285	Assistant	Tracie	Burns
1286	Assistant	Andrea	Sullivan
1287	Assistant	Debra	Knapp
1288	Assistant	Kenneth	Ellison
1289	Assistant	Christopher	Rollins
1290	Assistant	Emily	Miller
1291	Assistant	Andrew	Salazar
1292	Assistant	Mikayla	Hunt
1293	Assistant	Tyler	Holder
1294	Assistant	Todd	Jones
1295	Assistant	Amanda	Adams
1296	Assistant	James	Smith
1297	Assistant	Jonathan	Thomas
1298	Assistant	Anna	Santiago
1299	Assistant	Jessica	Rollins
1300	Assistant	Steven	Sanders
1301	Assistant	Jared	Wiggins
1302	Assistant	Timothy	Brooks
1303	Assistant	Jose	Perez
1304	Assistant	Debra	Hughes
1305	Assistant	Heather	Ramsey
1306	Assistant	Nicholas	Hernandez
1307	Assistant	Timothy	Howard
1308	Assistant	Marcia	Duncan
1309	Assistant	David	Johnson
1310	Assistant	Joshua	Owens
1311	Assistant	Alicia	Bell
1312	Assistant	Noah	Spencer
1313	Assistant	Martin	Austin
1314	Assistant	Andrea	Farley
1315	Assistant	Kristi	Payne
1316	Assistant	James	Jones
1317	Assistant	Jacob	Jacobs
1318	Assistant	Emily	Thomas
1319	Assistant	Scott	Ward
1320	Assistant	David	Adams
1321	Assistant	Mitchell	Fowler
1322	Assistant	Austin	Mccoy
1323	Assistant	Mitchell	Jenkins
1324	Assistant	Michelle	Smith
1325	Assistant	Sean	Moyer
1326	Assistant	Bradley	Fields
1327	Assistant	Melissa	Armstrong
1328	Assistant	Carolyn	Morris
1329	Assistant	Jennifer	Ramirez
1330	Assistant	Raymond	Reed
1331	Assistant	Michael	Hill
1332	Assistant	Jacob	Grant
1333	Assistant	Kimberly	Rivera
1334	Assistant	Michelle	Phillips
1335	Assistant	Alicia	Payne
1336	Assistant	Matthew	Wilson
1337	Assistant	Donald	Garcia
1338	Assistant	Corey	Townsend
1339	Assistant	Maria	Boyd
1340	Assistant	Diane	James
1341	Assistant	Mallory	Roach
1342	Assistant	Yvonne	Taylor
1343	Assistant	Leonard	Vargas
1344	Assistant	Jason	Anderson
1345	Assistant	Scott	Reed
1346	Assistant	Mike	Benjamin
1347	Assistant	Angelica	Peck
1348	Assistant	Bryan	Parker
1349	Assistant	Larry	Thompson
1350	Assistant	Jacqueline	Tucker
1351	Assistant	Rebecca	Jones
1352	Assistant	Anna	Gallagher
1353	Assistant	Heather	Diaz
1354	Assistant	Jessica	Holmes
1355	Assistant	Colleen	Ward
1356	Assistant	Jennifer	Houston
1357	Assistant	Daniel	Lewis
1358	Assistant	Louis	Bryant
1359	Assistant	Francisco	Holloway
1360	Assistant	Christine	Patton
1361	Assistant	Wyatt	Graham
1362	Assistant	Stephen	Williams
1363	Assistant	Shaun	Hart
1364	Assistant	Cindy	Bowman
1365	Assistant	Emily	Herrera
1366	Assistant	Amanda	Davis
1367	Assistant	Kyle	Hamilton
1368	Assistant	Jessica	Snyder
1369	Assistant	Jennifer	Cruz
1370	Assistant	Tiffany	Stokes
1371	Assistant	Amy	Burns
1372	Assistant	Maria	Castro
1373	Assistant	Joel	Miranda
1374	Assistant	Jennifer	Phillips
1375	Assistant	Robert	Williams
1376	Assistant	Natalie	Ward
1377	Assistant	Tiffany	Baker
1378	Assistant	Amy	Miller
1379	Assistant	Julie	Walker
1380	Assistant	Danielle	Harris
1381	Assistant	Mary	Miller
1382	Assistant	Alison	Berg
1383	Assistant	Mary	Flores
1384	Assistant	Rebecca	Miller
1385	Assistant	Kara	Ryan
1386	Assistant	Sarah	Daniels
1387	Assistant	Xavier	Brown
1388	Assistant	Daniel	Hanson
1389	Assistant	John	Nguyen
1390	Assistant	Victor	Palmer
1391	Assistant	Tiffany	Brown
1392	Assistant	Timothy	Harmon
1393	Assistant	Jessica	Villa
1394	Assistant	Casey	Schroeder
1395	Assistant	Denise	Ramirez
1396	Assistant	Karen	Parker
1397	Assistant	Nathan	Bishop
1398	Assistant	Tiffany	Murphy
1399	Assistant	Timothy	Powers
1400	Assistant	Joe	Butler
1401	Assistant	Nicole	Lindsey
1402	Assistant	Laura	West
1403	Assistant	John	Brewer
1404	Assistant	Dalton	Flowers
1405	Assistant	Rita	Edwards
1406	Assistant	Christopher	Smith
1407	Assistant	Joshua	Baldwin
1408	Assistant	Chelsea	Adams
1409	Assistant	Xavier	Francis
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
100	1
100	2
100	3
100	4
100	5
119	6
103	7
104	8
104	9
92	10
92	11
92	12
92	13
118	14
118	15
118	16
107	17
106	18
111	19
111	20
112	21
112	22
112	23
112	24
112	25
121	26
121	27
121	28
110	29
117	30
120	31
120	32
120	33
120	34
120	35
120	36
112	37
112	38
113	39
113	40
113	41
113	42
84	43
84	44
84	45
84	46
84	47
84	48
116	49
116	50
105	51
105	52
117	53
117	54
123	55
123	56
123	57
131	58
131	59
131	60
138	61
138	62
133	63
133	64
133	65
133	66
129	67
140	68
140	69
122	70
122	71
122	72
141	73
141	74
141	75
125	76
125	77
119	78
119	79
143	80
143	81
143	82
143	83
143	84
127	85
127	86
139	87
132	88
126	89
126	90
126	91
126	92
126	93
136	94
136	95
103	96
103	97
103	98
124	99
124	100
124	101
124	102
124	103
128	104
137	105
137	106
137	107
142	108
142	109
142	110
96	111
96	112
96	113
96	114
140	115
140	116
140	117
140	118
140	119
74	120
74	121
74	122
103	123
103	124
109	125
127	126
119	127
119	128
100	129
100	130
100	131
100	132
100	133
135	134
135	135
122	136
122	137
119	138
119	139
119	140
119	141
136	142
136	143
136	144
150	145
150	149
150	146
150	148
150	147
140	150
140	151
149	152
103	153
103	154
145	155
145	156
148	157
151	158
158	159
153	160
153	161
107	162
144	163
128	164
149	165
149	166
157	167
157	168
157	169
157	170
103	171
103	172
103	173
107	174
107	175
107	176
156	177
156	178
156	179
156	180
156	181
107	182
107	183
107	184
151	185
151	186
151	187
151	188
151	189
170	190
170	191
190	192
190	193
190	194
193	195
162	196
162	197
177	198
177	199
150	200
166	201
166	202
166	203
174	204
173	205
173	206
186	207
186	208
186	209
183	210
183	211
175	212
175	213
147	214
180	215
180	216
180	217
180	218
124	219
188	220
188	221
188	222
191	223
192	224
192	225
136	226
171	227
171	228
165	229
165	230
165	231
165	232
165	233
182	234
167	235
167	236
167	237
168	238
168	239
168	240
189	241
189	242
164	243
164	244
184	245
184	246
184	247
184	248
133	249
185	250
136	251
136	252
136	253
136	254
136	255
136	256
146	257
158	258
190	259
191	260
191	261
191	262
191	263
167	264
167	265
167	266
167	267
167	268
154	269
154	270
189	271
189	272
189	273
189	274
189	275
107	276
107	277
186	278
166	279
166	280
166	281
166	282
147	283
147	284
147	285
150	286
150	287
150	288
146	289
146	290
146	291
146	292
146	293
174	294
174	295
174	296
198	297
198	298
217	299
217	300
211	301
205	302
205	303
205	304
201	305
201	306
201	307
201	308
216	309
216	310
216	311
214	312
214	313
170	314
170	315
212	316
208	317
208	318
208	319
197	320
197	321
197	322
197	323
195	324
195	325
195	326
196	327
196	328
206	329
206	330
206	331
206	332
202	333
202	334
202	335
202	336
202	337
200	338
200	339
199	340
199	341
204	342
204	343
204	344
204	345
204	346
204	347
204	348
207	349
207	350
207	351
210	352
210	353
210	354
219	355
219	356
223	357
187	358
187	359
187	360
187	361
187	362
187	363
213	364
213	365
171	366
171	367
203	368
220	369
221	370
221	371
209	372
186	373
186	374
186	375
215	376
215	377
215	378
215	379
215	380
215	381
197	382
174	383
216	384
216	385
216	386
216	387
216	388
194	389
194	390
194	391
194	392
194	393
194	394
194	395
205	396
205	397
205	398
213	399
213	400
196	401
196	402
196	403
208	404
208	405
208	406
208	407
204	408
204	409
204	410
204	411
204	412
204	413
204	414
204	415
204	416
199	417
199	418
209	419
209	420
209	421
209	422
194	423
194	424
210	425
210	426
202	427
197	428
197	429
197	430
197	431
197	432
197	433
190	434
190	435
190	436
190	437
190	438
166	439
166	440
202	441
202	442
202	443
239	444
233	445
233	446
233	447
233	448
233	449
228	450
228	451
228	452
228	453
232	454
234	455
231	456
236	457
236	458
227	459
227	460
227	461
227	462
174	463
174	464
174	465
174	466
174	467
174	468
218	469
218	470
218	471
194	472
224	473
224	474
235	475
235	476
235	477
235	478
235	479
237	480
237	481
237	482
226	483
226	484
226	485
226	486
230	487
230	488
238	489
238	490
209	491
209	492
225	493
225	494
225	495
219	496
219	497
219	498
219	499
219	500
239	501
239	502
239	503
220	504
220	505
220	506
220	507
221	508
221	509
221	512
221	510
221	511
196	513
196	514
196	515
196	516
196	517
196	518
196	519
196	520
196	521
196	522
215	523
215	524
215	525
215	526
227	527
227	528
213	529
213	530
213	531
213	532
228	533
228	534
228	535
228	536
228	537
233	538
233	539
233	540
190	541
228	542
228	543
228	544
228	545
228	546
228	547
209	548
209	549
209	550
209	551
209	552
215	553
215	554
215	555
215	556
215	557
215	558
229	559
229	560
229	561
229	562
229	563
239	564
239	565
239	566
239	567
202	568
202	569
202	570
202	571
202	572
234	573
234	574
234	575
234	576
234	577
232	578
233	579
233	580
233	581
233	582
233	583
219	584
219	585
227	586
227	587
227	588
227	589
227	590
224	591
224	592
224	593
224	594
190	595
190	596
190	597
190	598
190	599
190	600
239	601
239	602
239	603
224	604
224	605
224	606
224	607
224	608
242	609
242	610
242	611
247	612
247	613
240	614
241	615
243	616
244	617
250	618
246	619
247	620
250	621
250	622
245	623
245	624
243	625
243	626
244	627
244	628
244	629
247	630
247	631
247	632
247	633
245	634
245	635
249	636
241	637
241	638
248	639
248	640
250	641
254	642
254	643
254	644
254	645
254	646
254	647
254	648
232	649
232	650
232	651
232	652
232	653
261	654
261	655
261	656
269	657
269	658
269	659
196	660
196	661
196	662
196	663
268	664
268	665
268	666
268	667
268	668
266	669
266	670
266	671
267	672
267	673
262	674
262	675
262	676
257	677
257	678
257	679
257	680
257	681
251	682
251	683
251	684
256	685
256	686
256	687
256	688
252	689
252	690
226	691
226	692
226	693
226	694
253	695
253	696
260	697
260	698
260	699
260	700
264	701
264	702
264	703
264	704
264	705
264	706
233	707
233	708
233	709
233	710
254	711
254	712
254	713
254	714
215	715
215	716
215	717
215	718
215	719
263	720
263	721
263	722
263	723
263	724
263	725
258	726
258	727
258	728
258	729
258	730
258	731
259	732
259	733
259	734
255	735
255	736
255	737
255	738
255	739
255	740
255	741
255	742
232	743
232	744
232	745
232	746
232	747
269	748
269	749
269	750
269	751
252	752
252	753
215	754
215	755
215	756
215	757
261	758
261	759
261	760
261	761
268	762
268	763
268	764
268	765
268	766
196	767
196	768
196	769
196	770
196	771
266	772
266	773
260	774
260	775
260	776
260	777
267	778
267	779
267	780
267	781
267	782
267	783
267	784
226	785
226	786
226	787
226	788
226	789
226	790
226	791
226	792
264	793
264	794
264	795
264	796
233	797
233	798
233	799
269	800
269	801
269	802
269	803
269	804
269	805
269	806
269	807
263	808
263	809
263	810
263	811
265	812
265	813
265	814
265	815
265	816
265	817
265	818
232	819
215	820
215	821
215	822
215	823
215	824
215	825
215	826
254	827
254	828
254	829
254	830
254	831
254	832
254	833
254	834
254	835
254	836
196	837
196	838
196	839
196	840
196	841
196	842
196	843
196	844
266	845
266	846
252	847
252	848
252	849
268	850
268	851
268	852
268	853
268	854
268	855
268	856
268	857
258	858
258	859
258	860
258	861
258	862
215	863
215	864
215	865
215	866
215	867
268	868
268	869
268	870
268	871
255	872
255	873
266	874
266	875
266	876
266	877
272	878
272	879
272	880
278	881
278	882
278	883
274	884
274	885
280	886
280	887
280	888
280	889
280	890
276	891
275	892
275	893
275	894
270	895
270	896
281	897
281	898
281	899
273	900
273	901
279	902
279	903
279	904
279	905
271	906
271	907
271	908
271	909
271	910
274	911
274	912
274	913
274	914
274	915
274	916
274	917
277	918
276	919
276	920
276	921
279	922
279	923
279	924
279	925
273	926
281	927
281	928
281	929
281	930
273	931
273	932
281	933
281	934
280	935
280	936
272	937
272	938
274	939
274	940
277	941
277	942
272	943
276	944
276	945
276	946
276	947
292	948
292	949
292	950
281	951
287	952
287	953
287	954
287	955
287	956
293	957
293	958
302	959
302	960
302	961
302	962
288	963
288	964
288	965
288	966
304	967
304	968
304	969
304	970
283	971
283	972
283	973
283	974
286	975
286	976
286	977
286	978
289	979
289	980
289	981
269	982
269	983
269	984
267	985
267	986
298	987
298	988
298	989
300	990
300	991
300	992
300	993
262	994
262	995
262	996
262	997
285	998
285	999
285	1000
285	1001
285	1002
306	1003
306	1004
306	1005
306	1006
65	1007
65	1008
65	1009
65	1010
282	1011
282	1012
282	1013
282	1014
282	1015
295	1016
295	1017
295	1018
295	1019
295	1020
295	1021
295	1022
247	1023
247	1024
247	1025
247	1026
247	1027
247	1028
247	1029
247	1030
247	1031
254	1032
254	1033
254	1034
254	1035
254	1036
254	1037
305	1038
305	1039
305	1040
305	1041
305	1042
305	1043
296	1044
296	1045
296	1046
296	1047
303	1048
303	1049
303	1050
303	1051
303	1052
290	1053
290	1054
290	1055
290	1056
290	1057
307	1058
307	1059
299	1060
301	1061
301	1062
301	1063
297	1064
297	1065
297	1066
294	1067
294	1068
294	1069
284	1070
284	1071
284	1072
284	1073
306	1074
306	1075
306	1076
306	1077
306	1078
306	1079
291	1080
291	1081
291	1082
291	1083
291	1084
283	1085
283	1086
255	1087
255	1088
255	1089
289	1090
289	1091
289	1092
289	1093
305	1094
305	1095
305	1096
281	1097
281	1098
269	1099
269	1100
269	1101
269	1102
304	1103
304	1104
304	1105
304	1106
304	1107
302	1108
302	1109
302	1110
302	1111
302	1112
302	1113
302	1114
293	1115
293	1116
293	1117
282	1118
282	1119
282	1120
285	1121
285	1122
285	1123
285	1124
285	1125
285	1126
285	1127
286	1128
286	1129
286	1130
254	1131
254	1132
254	1133
254	1134
254	1135
295	1136
295	1137
294	1138
294	1139
294	1140
294	1141
294	1142
294	1143
284	1144
284	1145
284	1146
284	1147
255	1148
255	1149
255	1150
255	1151
255	1152
297	1153
297	1154
298	1155
298	1156
298	1157
298	1158
298	1159
298	1160
292	1161
292	1162
292	1163
288	1164
288	1165
288	1166
288	1167
288	1168
299	1169
299	1170
299	1171
299	1172
299	1173
299	1174
299	1175
290	1176
290	1177
290	1178
290	1179
290	1180
282	1181
282	1182
282	1183
282	1184
282	1185
282	1186
254	1187
254	1188
254	1189
254	1190
254	1191
301	1192
301	1193
301	1194
301	1195
301	1196
255	1197
255	1198
255	1199
255	1200
255	1201
255	1202
292	1203
292	1204
292	1205
292	1206
293	1207
293	1208
293	1209
293	1210
293	1211
293	1212
285	1213
285	1214
285	1215
285	1216
255	1217
255	1218
330	1219
330	1220
330	1221
330	1222
333	1223
333	1224
333	1225
322	1226
322	1227
322	1228
348	1229
348	1230
348	1231
336	1232
336	1233
336	1234
336	1235
336	1236
336	1237
336	1238
336	1239
346	1240
346	1241
346	1242
327	1243
327	1244
327	1245
242	1246
331	1247
331	1248
331	1249
331	1250
328	1251
328	1252
328	1253
328	1254
347	1255
347	1256
347	1257
347	1258
347	1259
347	1260
347	1261
334	1262
334	1263
334	1264
334	1265
334	1266
343	1267
343	1268
343	1269
343	1270
343	1271
341	1272
341	1273
341	1274
341	1275
337	1276
337	1277
337	1278
323	1279
323	1280
323	1281
323	1282
323	1283
323	1284
329	1285
329	1286
342	1287
342	1288
342	1289
342	1290
342	1291
342	1292
339	1293
339	1294
339	1295
282	1296
282	1297
282	1298
282	1299
289	1300
289	1301
289	1302
344	1303
344	1304
344	1305
344	1306
344	1307
344	1308
340	1309
340	1310
326	1311
326	1312
325	1313
325	1314
325	1315
325	1316
325	1317
325	1318
324	1319
324	1320
324	1321
324	1322
324	1323
335	1324
335	1325
335	1326
335	1327
335	1328
335	1329
297	1330
297	1331
297	1332
345	1333
345	1334
345	1335
345	1336
345	1337
290	1338
290	1339
290	1340
290	1341
290	1342
298	1343
298	1344
298	1345
349	1346
349	1347
349	1348
349	1349
349	1350
349	1351
349	1352
349	1353
349	1354
349	1355
349	1356
349	1357
332	1358
332	1359
332	1360
332	1361
332	1362
332	1363
332	1364
332	1365
332	1366
332	1367
332	1368
332	1369
332	1370
332	1371
338	1372
338	1373
255	1374
255	1375
255	1376
255	1377
255	1378
255	1379
342	1380
342	1381
342	1382
342	1383
342	1384
342	1385
333	1386
333	1387
333	1388
333	1389
282	1390
343	1391
343	1392
343	1393
343	1394
343	1395
343	1396
334	1397
334	1398
334	1399
346	1400
346	1401
346	1402
346	1403
346	1404
346	1405
346	1406
299	1407
299	1408
299	1409
299	1410
299	1411
348	1412
348	1413
242	1414
242	1415
242	1416
242	1417
242	1418
344	1419
344	1420
344	1421
344	1422
344	1423
344	1424
344	1425
323	1426
323	1427
323	1428
323	1429
323	1430
335	1431
335	1432
322	1433
322	1434
326	1435
326	1436
326	1437
298	1438
298	1439
298	1440
298	1441
298	1442
298	1443
298	1444
298	1445
298	1446
298	1447
298	1448
341	1449
341	1450
289	1451
289	1452
289	1453
289	1454
337	1455
337	1456
337	1457
337	1458
337	1459
337	1460
337	1461
337	1462
342	1463
342	1464
342	1465
290	1466
290	1467
290	1468
290	1469
290	1470
290	1471
290	1472
282	1473
282	1474
282	1475
343	1476
343	1477
343	1478
343	1479
297	1480
297	1481
297	1482
299	1483
299	1484
299	1485
333	1486
333	1487
333	1488
289	1489
289	1490
319	1491
319	1492
318	1493
318	1494
318	1495
318	1496
314	1497
314	1498
314	1499
314	1500
310	1501
310	1502
310	1503
310	1504
354	1505
354	1506
354	1507
316	1508
316	1509
316	1510
308	1511
308	1512
272	1513
350	1514
350	1515
353	1516
354	1517
354	1518
354	1519
354	1520
318	1521
318	1522
318	1523
318	1524
316	1525
316	1526
310	1527
310	1528
310	1529
352	1530
351	1531
351	1532
314	1533
353	1534
353	1535
353	1536
353	1537
350	1538
350	1539
352	1540
354	1541
354	1542
354	1543
354	1544
318	1545
318	1546
318	1547
318	1548
314	1549
319	1550
319	1551
319	1552
319	1553
310	1554
316	1555
316	1556
360	1557
330	1558
330	1559
330	1560
366	1561
366	1562
366	1563
363	1564
363	1565
363	1566
359	1567
359	1568
359	1569
359	1570
359	1571
335	1572
335	1573
335	1574
335	1575
335	1576
335	1577
367	1578
367	1579
367	1580
362	1581
362	1582
362	1583
362	1584
362	1585
355	1586
355	1587
355	1588
355	1589
355	1590
355	1591
355	1592
356	1593
356	1594
356	1595
356	1596
356	1597
356	1598
346	1599
346	1600
346	1601
346	1602
346	1603
340	1604
340	1605
340	1606
340	1607
340	1608
361	1609
361	1610
361	1611
361	1612
361	1613
361	1614
361	1615
361	1616
357	1617
357	1618
357	1619
357	1620
358	1621
358	1622
358	1623
345	1624
345	1625
345	1626
345	1627
364	1628
364	1629
364	1630
364	1631
364	1632
364	1633
324	1634
324	1635
324	1636
324	1637
324	1638
330	1639
330	1640
330	1641
330	1642
330	1643
330	1644
336	1645
336	1646
336	1647
336	1648
336	1649
336	1650
336	1651
336	1652
367	1653
367	1654
367	1655
367	1656
367	1657
343	1658
343	1659
343	1660
343	1661
343	1662
343	1663
343	1664
363	1665
363	1666
363	1667
363	1668
363	1669
365	1670
365	1671
365	1672
365	1673
365	1674
365	1675
365	1676
360	1677
360	1678
360	1679
360	1680
360	1681
360	1682
360	1683
360	1684
362	1685
362	1686
362	1687
362	1688
362	1689
359	1690
359	1691
359	1692
359	1693
359	1694
335	1695
335	1696
335	1697
335	1698
335	1699
357	1700
357	1701
357	1702
357	1703
356	1704
356	1705
356	1706
356	1707
340	1708
340	1709
340	1710
340	1711
340	1712
340	1713
346	1714
346	1715
346	1716
346	1717
346	1718
346	1719
346	1720
346	1721
363	1722
363	1723
363	1724
363	1725
363	1726
363	1727
363	1728
363	1729
363	1730
363	1731
361	1732
361	1733
367	1734
367	1735
367	1736
367	1737
358	1738
358	1739
358	1740
345	1741
345	1742
345	1743
345	1744
345	1745
345	1746
336	1747
336	1748
336	1749
336	1750
336	1751
336	1752
336	1753
336	1754
366	1755
366	1756
366	1757
366	1758
366	1759
366	1760
366	1761
364	1762
364	1763
364	1764
364	1765
364	1766
357	1767
357	1768
335	1769
335	1770
335	1771
335	1772
335	1773
340	1774
340	1775
340	1776
340	1777
340	1778
365	1779
365	1780
324	1781
324	1782
324	1783
324	1784
324	1785
356	1786
356	1787
356	1788
356	1789
356	1790
356	1791
356	1792
360	1793
360	1794
360	1795
360	1796
360	1797
360	1798
360	1799
360	1800
360	1801
360	1802
362	1803
362	1804
362	1805
362	1806
346	1807
346	1808
346	1809
346	1810
358	1811
358	1812
358	1813
358	1814
358	1815
358	1816
359	1817
359	1818
359	1819
359	1820
359	1821
359	1822
361	1823
361	1824
361	1825
361	1826
361	1827
361	1828
361	1829
361	1830
361	1831
361	1832
361	1833
361	1834
364	1835
364	1836
364	1837
364	1838
364	1839
364	1840
364	1841
357	1842
336	1843
336	1844
336	1845
336	1846
336	1847
336	1848
336	1849
367	1850
367	1851
367	1852
367	1853
336	1854
336	1855
336	1856
336	1857
336	1858
336	1859
336	1860
336	1861
359	1862
359	1863
359	1864
360	1865
360	1866
360	1867
360	1868
360	1869
364	1870
364	1871
364	1872
364	1873
364	1874
364	1875
364	1876
357	1877
357	1878
357	1879
362	1880
362	1881
330	1882
330	1883
330	1884
330	1885
330	1886
360	1887
360	1888
360	1889
360	1890
360	1891
316	1892
316	1893
316	1894
316	1895
316	1896
316	1897
318	1898
318	1899
319	1900
319	1901
375	1902
370	1903
370	1904
370	1905
374	1906
372	1907
372	1908
372	1909
371	1910
373	1911
373	1912
377	1913
377	1914
377	1915
377	1916
377	1917
316	1918
316	1919
316	1920
318	1921
318	1922
318	1923
318	1924
376	1925
376	1926
376	1927
369	1928
369	1929
369	1930
369	1931
369	1932
372	1933
372	1934
372	1935
372	1936
370	1937
370	1938
370	1939
376	1940
368	1941
368	1942
368	1943
368	1944
373	1945
373	1946
369	1947
369	1948
319	1949
319	1950
371	1951
371	1952
371	1953
316	1954
373	1955
373	1956
373	1957
373	1958
368	1959
368	1960
371	1961
318	1962
318	1963
318	1964
318	1965
318	1966
373	1967
316	1968
316	1969
316	1970
384	1971
384	1972
384	1973
384	1974
388	1975
388	1976
388	1977
388	1978
388	1979
388	1980
383	1981
390	1982
390	1983
346	1984
346	1985
346	1986
346	1987
346	1988
346	1989
323	1990
323	1991
323	1992
323	1993
379	1994
379	1995
379	1996
379	1997
379	1998
366	1999
366	2000
366	2001
366	2002
366	2003
366	2004
386	2005
386	2006
386	2007
380	2008
380	2009
357	2010
357	2011
382	2012
382	2013
382	2014
362	2015
362	2016
362	2017
385	2018
387	2019
387	2020
387	2021
392	2022
392	2023
392	2024
392	2025
358	2026
358	2027
358	2028
359	2029
359	2030
359	2031
359	2032
359	2033
343	2034
343	2035
343	2036
343	2037
343	2038
378	2039
378	2040
378	2041
378	2042
378	2043
378	2044
391	2045
391	2046
391	2047
391	2048
391	2049
391	2050
391	2051
391	2052
381	2053
381	2054
381	2055
381	2056
381	2057
384	2058
384	2059
379	2060
367	2061
367	2062
367	2063
367	2064
367	2065
362	2066
362	2067
362	2068
362	2069
387	2070
387	2071
387	2072
387	2073
387	2074
323	2075
323	2076
323	2077
386	2078
386	2079
386	2080
386	2081
389	2082
389	2083
389	2084
389	2085
378	2086
378	2087
378	2088
378	2089
378	2090
378	2091
378	2092
378	2093
378	2094
378	2095
388	2096
388	2097
343	2098
343	2099
385	2100
385	2101
385	2102
384	2103
384	2104
380	2105
380	2106
380	2107
380	2108
390	2109
390	2110
390	2111
390	2112
359	2113
359	2114
359	2115
359	2116
359	2117
362	2118
362	2119
362	2120
362	2121
362	2122
346	2123
346	2124
388	2125
388	2126
388	2127
392	2128
392	2129
392	2130
392	2131
392	2132
392	2133
392	2134
392	2135
389	2136
389	2137
389	2138
389	2139
389	2140
382	2141
382	2142
382	2143
382	2144
382	2145
357	2146
357	2147
357	2148
357	2149
357	2150
357	2151
357	2152
366	2153
366	2154
366	2155
379	2156
379	2157
379	2158
379	2159
379	2160
390	2161
390	2162
390	2163
385	2164
385	2165
385	2166
385	2167
385	2168
362	2169
362	2170
367	2171
391	2172
391	2173
391	2174
391	2175
391	2176
392	2177
392	2178
392	2179
392	2180
392	2181
359	2182
359	2183
359	2184
359	2185
359	2186
379	2187
379	2188
379	2189
388	2190
388	2191
388	2192
388	2193
388	2194
388	2195
380	2196
380	2197
380	2198
380	2199
380	2200
380	2201
380	2202
384	2203
384	2204
384	2205
323	2206
323	2207
323	2208
323	2209
323	2210
323	2211
384	2212
384	2213
384	2214
384	2215
384	2216
357	2217
357	2218
357	2219
357	2220
392	2221
392	2222
392	2223
392	2224
392	2225
392	2226
392	2227
392	2228
392	2229
392	2230
392	2231
392	2232
392	2233
399	2234
399	2235
398	2236
398	2237
398	2238
402	2239
402	2240
396	2241
393	2242
393	2243
397	2244
397	2245
395	2246
395	2247
394	2248
371	2249
373	2250
373	2251
373	2252
373	2253
319	2254
377	2255
377	2256
404	2257
398	2258
398	2259
398	2260
398	2261
398	2262
398	2263
394	2264
394	2265
394	2266
403	2267
403	2268
403	2269
403	2270
403	2271
397	2272
397	2273
377	2274
377	2275
377	2276
377	2277
393	2278
393	2279
393	2280
393	2281
393	2282
402	2283
402	2284
402	2285
402	2286
399	2287
399	2288
399	2289
399	2290
399	2291
399	2292
399	2293
399	2294
399	2295
398	2296
396	2297
319	2298
388	2299
388	2300
388	2301
388	2302
421	2303
421	2304
420	2305
420	2306
420	2307
420	2308
408	2309
408	2310
408	2311
408	2312
411	2313
411	2314
411	2315
406	2316
406	2317
406	2318
406	2319
413	2320
416	2321
416	2322
416	2323
416	2324
384	2325
384	2326
419	2327
419	2328
419	2329
419	2330
419	2331
419	2332
405	2333
405	2334
414	2335
414	2336
424	2337
409	2338
409	2339
366	2340
366	2341
407	2342
407	2343
407	2344
407	2345
417	2346
417	2347
417	2348
417	2349
412	2350
412	2351
411	2352
411	2353
411	2354
418	2355
418	2356
392	2357
392	2358
423	2359
423	2360
405	2361
405	2362
405	2363
405	2364
416	2365
416	2366
413	2367
425	2368
425	2369
425	2370
425	2371
425	2372
414	2373
414	2374
419	2375
415	2376
415	2377
406	2378
406	2379
406	2380
421	2381
421	2382
421	2383
417	2384
422	2385
422	2386
422	2387
410	2388
410	2389
409	2390
409	2391
409	2392
384	2393
384	2394
384	2395
384	2396
412	2397
412	2398
412	2399
366	2400
366	2401
366	2402
366	2403
366	2404
418	2405
418	2406
424	2407
424	2408
424	2409
423	2410
423	2411
420	2412
420	2413
417	2414
408	2415
408	2416
422	2417
422	2418
422	2419
422	2420
384	2421
384	2422
384	2423
407	2424
407	2425
407	2426
407	2427
407	2428
425	2429
425	2430
425	2431
392	2432
392	2433
392	2434
392	2435
392	2436
392	2437
392	2438
413	2439
413	2440
413	2441
418	2442
418	2443
418	2444
425	2445
425	2446
425	2447
425	2448
425	2449
425	2450
425	2451
411	2452
419	2453
419	2454
409	2455
409	2456
409	2457
409	2458
409	2459
412	2460
412	2461
417	2462
417	2463
423	2464
423	2465
423	2466
423	2467
420	2468
420	2469
420	2470
384	2471
384	2472
384	2473
384	2474
384	2475
384	2476
366	2477
407	2478
407	2479
407	2480
412	2481
412	2482
412	2483
412	2484
412	2485
420	2486
420	2487
420	2488
420	2489
438	2490
393	2491
393	2492
432	2493
432	2494
396	2495
396	2496
396	2497
396	2498
396	2499
396	2500
433	2501
433	2502
433	2503
433	2504
433	2505
442	2506
442	2507
443	2508
443	2509
443	2510
437	2511
428	2512
400	2513
400	2514
400	2515
400	2516
441	2517
426	2518
403	2519
403	2520
403	2521
429	2522
431	2523
430	2524
430	2525
434	2526
439	2527
439	2528
396	2529
396	2530
432	2531
432	2532
444	2533
444	2534
444	2535
435	2536
428	2537
428	2538
433	2539
433	2540
433	2541
433	2542
440	2543
440	2544
442	2545
442	2546
442	2547
442	2548
442	2549
427	2550
427	2551
427	2552
438	2553
438	2554
438	2555
438	2556
396	2557
396	2558
396	2559
396	2560
445	2561
445	2562
432	2563
432	2564
440	2565
440	2566
440	2567
403	2568
426	2569
426	2570
428	2571
428	2572
428	2573
432	2574
432	2575
432	2576
430	2577
430	2578
430	2579
430	2580
443	2581
396	2582
396	2583
396	2584
396	2585
396	2586
396	2587
444	2588
438	2589
442	2590
442	2591
426	2592
426	2593
426	2594
426	2595
432	2596
432	2597
440	2598
440	2599
440	2600
438	2601
438	2602
417	2603
417	2604
413	2605
413	2606
407	2607
407	2608
407	2609
407	2610
458	2611
458	2612
448	2613
448	2614
448	2615
448	2616
410	2617
410	2618
410	2619
419	2620
419	2621
419	2622
449	2623
449	2624
449	2625
449	2626
450	2627
450	2628
450	2629
450	2630
457	2631
457	2632
457	2633
457	2634
405	2635
405	2636
405	2637
459	2638
459	2639
459	2640
459	2641
459	2642
459	2643
459	2644
459	2645
421	2646
460	2647
460	2648
460	2649
460	2650
422	2651
422	2652
422	2653
446	2654
446	2655
411	2656
411	2657
448	2658
448	2659
456	2660
456	2661
452	2662
452	2663
452	2664
452	2665
384	2666
384	2667
384	2668
384	2669
384	2670
384	2671
384	2672
413	2673
413	2674
413	2675
447	2676
406	2677
406	2678
406	2679
406	2680
406	2681
455	2682
414	2683
414	2684
414	2685
414	2686
454	2687
454	2688
454	2689
451	2690
451	2691
451	2692
451	2693
458	2694
458	2695
458	2696
458	2697
458	2698
457	2699
457	2700
421	2701
421	2702
449	2703
449	2704
449	2705
384	2706
384	2707
384	2708
384	2709
384	2710
384	2711
446	2712
446	2713
446	2714
446	2715
446	2716
446	2717
453	2718
453	2719
453	2720
453	2721
453	2722
453	2723
419	2724
456	2725
456	2726
456	2727
456	2728
456	2729
407	2730
407	2731
407	2732
407	2733
407	2734
411	2735
411	2736
411	2737
411	2738
417	2739
417	2740
417	2741
417	2742
417	2743
450	2744
450	2745
450	2746
461	2747
461	2748
461	2749
461	2750
461	2751
461	2752
459	2753
414	2754
414	2755
460	2756
460	2757
422	2758
422	2759
422	2760
422	2761
422	2762
422	2763
450	2764
450	2765
450	2766
450	2767
450	2768
450	2769
450	2770
450	2771
457	2772
413	2773
413	2774
413	2775
417	2776
458	2777
458	2778
458	2779
458	2780
458	2781
458	2782
449	2783
460	2784
460	2785
460	2786
460	2787
411	2788
411	2789
411	2790
411	2791
411	2792
411	2793
411	2794
411	2795
417	2796
417	2797
417	2798
417	2799
414	2800
414	2801
414	2802
414	2803
413	2804
413	2805
413	2806
419	2807
419	2808
419	2809
419	2810
419	2811
448	2812
448	2813
448	2814
448	2815
448	2816
407	2817
407	2818
407	2819
450	2820
450	2821
450	2822
417	2823
417	2824
417	2825
464	2826
464	2827
464	2828
464	2829
464	2830
466	2831
466	2832
466	2833
466	2834
469	2835
469	2836
427	2837
427	2838
427	2839
427	2840
468	2841
468	2842
468	2843
462	2844
462	2845
430	2846
430	2847
430	2848
440	2849
440	2850
443	2851
443	2852
443	2853
467	2854
471	2855
471	2856
471	2857
438	2858
403	2859
403	2860
441	2861
441	2862
441	2863
433	2864
473	2865
473	2866
432	2867
432	2868
439	2869
439	2870
439	2871
472	2872
472	2873
472	2874
470	2875
470	2876
468	2877
468	2878
468	2879
468	2880
468	2881
463	2882
465	2883
465	2884
465	2885
465	2886
427	2887
427	2888
427	2889
427	2890
464	2891
464	2892
443	2893
443	2894
443	2895
433	2896
433	2897
440	2898
440	2899
440	2900
440	2901
438	2902
438	2903
430	2904
430	2905
430	2906
430	2907
471	2908
471	2909
432	2910
432	2911
474	2912
474	2913
474	2914
474	2915
474	2916
468	2917
468	2918
468	2919
468	2920
439	2921
439	2922
464	2923
464	2924
464	2925
464	2926
464	2927
433	2928
433	2929
469	2930
469	2931
469	2932
427	2933
443	2934
438	2935
438	2936
442	2937
442	2938
442	2939
442	2940
430	2941
463	2942
463	2943
463	2944
463	2945
464	2946
464	2947
464	2948
471	2949
471	2950
430	2951
430	2952
430	2953
486	2954
486	2955
486	2956
486	2957
486	2958
486	2959
478	2960
478	2961
488	2962
488	2963
488	2964
475	2965
475	2966
475	2967
475	2968
475	2969
475	2970
493	2971
493	2972
493	2973
493	2974
493	2975
493	2976
457	2977
457	2978
457	2979
477	2980
477	2981
477	2982
482	2983
482	2984
482	2985
487	2986
452	2987
452	2988
459	2989
459	2990
459	2991
459	2992
459	2993
491	2994
491	2995
491	2996
461	2997
461	2998
479	2999
479	3000
479	3001
479	3002
479	3003
479	3004
450	3005
450	3006
450	3007
480	3008
480	3009
480	3010
480	3011
456	3012
456	3013
456	3014
456	3015
456	3016
456	3017
481	3018
489	3019
489	3020
489	3021
488	3022
488	3023
488	3024
488	3025
488	3026
454	3027
454	3028
454	3029
486	3030
486	3031
486	3032
486	3033
486	3034
485	3035
485	3036
485	3037
485	3038
485	3039
485	3040
457	3041
457	3042
484	3043
484	3044
484	3045
484	3046
483	3047
483	3048
483	3049
483	3050
452	3051
452	3052
452	3053
452	3054
490	3055
490	3056
490	3057
490	3058
476	3059
476	3060
450	3061
450	3062
450	3063
450	3064
450	3065
461	3066
410	3067
456	3068
456	3069
456	3070
456	3071
493	3072
493	3073
481	3074
481	3075
481	3076
447	3077
483	3078
483	3079
485	3080
485	3081
485	3082
485	3083
485	3084
485	3085
485	3086
478	3087
478	3088
478	3089
478	3090
490	3091
430	3092
482	3093
482	3094
482	3095
489	3096
489	3097
489	3098
489	3099
489	3100
489	3101
489	3102
491	3103
491	3104
479	3105
479	3106
479	3107
479	3108
479	3109
479	3110
487	3111
487	3112
487	3113
487	3114
487	3115
487	3116
487	3117
487	3118
487	3119
487	3120
487	3121
488	3122
488	3123
454	3124
454	3125
492	3126
492	3127
492	3128
476	3129
479	3130
479	3131
461	3132
487	3133
487	3134
457	3135
457	3136
485	3137
485	3138
485	3139
485	3140
485	3141
456	3142
456	3143
456	3144
456	3145
456	3146
456	3147
456	3148
456	3149
456	3150
456	3151
456	3152
456	3153
456	3154
491	3155
491	3156
491	3157
488	3158
488	3159
488	3160
488	3161
486	3162
486	3163
486	3164
486	3165
457	3166
475	3167
475	3168
454	3169
454	3170
454	3171
454	3172
454	3173
454	3174
454	3175
\.


--
-- Data for Name: equipe; Type: TABLE DATA; Schema: public; Owner: wcuser
--

COPY public.equipe (nompays, anneecoupe, id_selectionneur, id_equipe) FROM stdin;
Peru	1930	1	9
France	1930	2	6
Brazil	1930	3	4
Paraguay	1930	4	8
Belgium	1930	5	2
Mexico	1930	6	7
United States	1930	7	11
Argentina	1930	8	1
Chile	1930	9	5
Romania	1930	10	10
Bolivia	1930	11	3
Yugoslavia	1930	12	13
Uruguay	1930	13	12
Spain	1934	15	26
Netherlands	1934	16	24
Belgium	1934	17	16
United States	1934	18	29
France	1934	19	20
Egypt	1934	20	19
Austria	1934	21	15
Switzerland	1934	22	28
Hungary	1934	23	22
Germany	1934	24	21
Argentina	1934	25	14
Czechoslovakia	1934	26	18
Sweden	1934	27	27
Italy	1934	28	23
Romania	1934	29	25
Brazil	1934	31	17
France	1938	32	35
Belgium	1938	33	30
Hungary	1938	34	37
Netherlands	1938	35	39
Norway	1938	36	40
Germany	1938	37	36
Poland	1938	38	41
Dutch East Indies	1938	39	34
Czechoslovakia	1938	40	33
Sweden	1938	41	43
Brazil	1938	42	31
Italy	1938	43	38
Romania	1938	44	42
Switzerland	1938	45	44
Cuba	1938	48	32
Switzerland	1950	49	54
Yugoslavia	1950	50	57
Chile	1950	51	47
Brazil	1950	52	46
Spain	1950	53	52
Paraguay	1950	54	51
United States	1950	55	55
Uruguay	1950	56	56
Italy	1950	57	49
Bolivia	1950	58	45
Sweden	1950	59	53
Mexico	1950	60	50
England	1950	61	48
Scotland	1954	62	67
Czechoslovakia	1954	63	61
Italy	1954	64	65
West Germany	1954	65	72
South Korea	1954	66	68
Belgium	1954	67	59
Uruguay	1954	68	71
Mexico	1954	69	66
Brazil	1954	70	60
Austria	1954	71	58
France	1954	72	63
Turkey	1954	73	70
Switzerland	1954	74	69
Hungary	1954	75	64
Yugoslavia	1954	76	73
England	1954	77	62
Austria	1958	78	75
Hungary	1958	79	80
France	1958	80	79
Scotland	1958	81	84
Northern Ireland	1958	82	82
Brazil	1958	83	76
Paraguay	1958	84	83
West Germany	1958	85	88
Soviet Union	1958	86	85
Czechoslovakia	1958	87	77
Mexico	1958	88	81
Wales	1958	89	87
Sweden	1958	90	86
Argentina	1958	91	74
Yugoslavia	1958	92	89
England	1958	94	78
Hungary	1962	95	97
Uruguay	1962	96	103
Italy	1962	97	98
West Germany	1962	98	104
Spain	1962	99	101
Soviet Union	1962	100	100
Argentina	1962	101	90
Yugoslavia	1962	102	105
Brazil	1962	105	91
Bulgaria	1962	106	92
Colombia	1962	107	94
Switzerland	1962	108	102
Chile	1962	109	93
Mexico	1962	110	99
Czechoslovakia	1962	111	95
England	1962	112	96
Chile	1966	113	109
Hungary	1966	114	112
Italy	1966	115	113
Brazil	1966	116	107
Switzerland	1966	117	119
Portugal	1966	118	116
France	1966	119	111
Argentina	1966	120	106
Soviet Union	1966	121	117
North Korea	1966	122	115
England	1966	123	110
West Germany	1966	124	121
Mexico	1966	125	114
Uruguay	1966	126	120
Spain	1966	127	118
Bulgaria	1966	128	108
Sweden	1970	129	135
Bulgaria	1970	130	124
Mexico	1970	131	130
El Salvador	1970	132	126
Peru	1970	133	132
Belgium	1970	134	122
Uruguay	1970	135	136
Soviet Union	1970	136	134
Czechoslovakia	1970	137	125
Romania	1970	138	133
England	1970	139	127
Israel	1970	140	128
West Germany	1970	141	137
Italy	1970	142	129
Morocco	1970	143	131
Brazil	1970	144	123
Chile	1974	145	142
East Germany	1974	146	143
Argentina	1974	147	138
Sweden	1974	148	149
Poland	1974	149	147
Netherlands	1974	150	146
Yugoslavia	1974	151	152
Bulgaria	1974	152	141
Scotland	1974	153	148
Uruguay	1974	154	150
Australia	1974	155	139
West Germany	1974	156	151
Haiti	1974	157	144
Italy	1974	158	145
Zaire	1974	159	153
Brazil	1974	160	140
Hungary	1978	161	158
Italy	1978	162	160
Peru	1978	163	163
Tunisia	1978	164	168
Brazil	1978	165	156
Sweden	1978	166	167
Poland	1978	167	164
Netherlands	1978	168	162
France	1978	169	157
Spain	1978	170	166
Scotland	1978	171	165
Argentina	1978	172	154
Iran	1978	173	159
Mexico	1978	174	161
West Germany	1978	175	169
Austria	1978	176	155
New Zealand	1982	177	185
Italy	1982	178	183
Soviet Union	1982	179	190
Northern Ireland	1982	180	186
Honduras	1982	181	181
West Germany	1982	182	192
England	1982	183	179
France	1982	184	180
Algeria	1982	185	170
Austria	1982	186	172
Argentina	1982	188	171
Hungary	1982	189	182
Yugoslavia	1982	190	193
Kuwait	1982	191	184
Poland	1982	192	188
El Salvador	1982	193	178
Spain	1982	194	191
Brazil	1982	195	174
Chile	1982	196	176
Scotland	1982	198	189
Belgium	1982	199	173
Peru	1982	200	187
Czechoslovakia	1982	201	177
Cameroon	1982	202	175
Italy	1986	203	205
West Germany	1986	204	217
Argentina	1986	205	195
Northern Ireland	1986	206	208
Uruguay	1986	207	216
Iraq	1986	208	204
Morocco	1986	209	207
Scotland	1986	210	212
South Korea	1986	211	213
Soviet Union	1986	212	214
Hungary	1986	213	203
France	1986	214	202
Mexico	1986	215	206
Spain	1986	216	215
Poland	1986	217	210
Denmark	1986	218	200
Paraguay	1986	219	209
England	1986	220	201
Algeria	1986	221	194
Brazil	1986	222	197
Belgium	1986	223	196
Portugal	1986	224	211
Bulgaria	1986	225	198
Canada	1986	226	199
Egypt	1990	227	226
West Germany	1990	228	240
Netherlands	1990	229	229
Argentina	1990	230	218
Republic of Ireland	1990	231	230
United States	1990	232	238
Austria	1990	233	219
Romania	1990	234	231
Brazil	1990	235	221
South Korea	1990	236	233
Soviet Union	1990	237	234
Colombia	1990	238	223
Costa Rica	1990	239	224
Cameroon	1990	240	222
Sweden	1990	241	236
Yugoslavia	1990	242	241
United Arab Emirates	1990	243	237
England	1990	244	227
Scotland	1990	245	232
Spain	1990	246	235
Uruguay	1990	247	239
Belgium	1990	248	220
Czechoslovakia	1990	249	225
Italy	1990	250	228
Germany	1991	251	246
New Zealand	1991	252	249
Nigeria	1991	253	250
Chinese Taipei	1991	254	244
United States	1991	255	253
Denmark	1991	256	245
Italy	1991	257	247
Sweden	1991	258	252
Norway	1991	259	251
Brazil	1991	260	242
China	1991	261	243
Japan	1991	262	248
Netherlands	1994	263	266
Bolivia	1994	264	256
Argentina	1994	265	254
Morocco	1994	266	265
Republic of Ireland	1994	267	269
Spain	1994	268	274
Switzerland	1994	269	276
Romania	1994	270	270
South Korea	1994	271	273
Colombia	1994	272	260
Mexico	1994	273	264
Cameroon	1994	274	259
United States	1994	275	277
Norway	1994	276	268
Greece	1994	277	262
Brazil	1994	278	257
Bulgaria	1994	279	258
Italy	1994	280	263
Russia	1994	281	271
Saudi Arabia	1994	282	272
Sweden	1994	283	275
Belgium	1994	284	255
Germany	1994	285	261
Nigeria	1994	286	267
Canada	1995	287	280
Germany	1995	288	284
England	1995	289	283
United States	1995	290	289
Brazil	1995	291	279
Denmark	1995	292	282
Nigeria	1995	293	286
China	1995	294	281
Norway	1995	295	287
Australia	1995	296	278
Sweden	1995	297	288
Japan	1995	298	285
Chile	1998	299	296
Saudi Arabia	1998	300	314
Croatia	1998	301	298
Bulgaria	1998	302	294
Scotland	1998	303	315
Paraguay	1998	304	312
South Korea	1998	305	317
Spain	1998	306	318
Colombia	1998	307	297
Netherlands	1998	308	309
England	1998	309	300
Romania	1998	310	313
France	1998	311	301
Denmark	1998	312	299
Tunisia	1998	313	319
Mexico	1998	314	307
Cameroon	1998	315	295
Belgium	1998	316	292
Italy	1998	317	304
Morocco	1998	318	308
Nigeria	1998	319	310
Japan	1998	320	306
Norway	1998	321	311
Argentina	1998	323	290
Austria	1998	324	291
United States	1998	325	320
Yugoslavia	1998	326	321
Jamaica	1998	328	305
Iran	1998	329	303
South Africa	1998	330	316
Germany	1998	331	302
Brazil	1998	332	293
Ghana	1999	333	328
Australia	1999	334	322
Russia	1999	335	335
Mexico	1999	336	331
United States	1999	337	337
Sweden	1999	338	336
Italy	1999	339	329
Norway	1999	340	334
Denmark	1999	341	326
Nigeria	1999	342	332
China	1999	343	325
Japan	1999	344	330
North Korea	1999	345	333
Germany	1999	346	327
Canada	1999	347	324
Brazil	1999	348	323
Mexico	2002	349	352
Saudi Arabia	2002	350	359
United States	2002	351	368
Argentina	2002	352	338
Spain	2002	353	364
Poland	2002	354	355
England	2002	355	347
Ecuador	2002	356	346
Costa Rica	2002	357	343
Turkey	2002	358	367
South Korea	2002	359	363
Croatia	2002	360	344
Slovenia	2002	361	361
Sweden	2002	362	365
France	2002	363	348
Paraguay	2002	364	354
Republic of Ireland	2002	365	357
Senegal	2002	366	360
China	2002	367	342
Portugal	2002	368	356
Denmark	2002	369	345
Nigeria	2002	370	353
Uruguay	2002	371	369
Russia	2002	372	358
Cameroon	2002	373	341
Brazil	2002	374	340
South Africa	2002	376	362
Tunisia	2002	377	366
Italy	2002	378	350
Japan	2002	379	351
Germany	2002	380	349
Belgium	2002	381	339
South Korea	2003	382	383
Ghana	2003	383	377
Argentina	2003	384	370
Russia	2003	385	382
Sweden	2003	386	384
Brazil	2003	387	372
United States	2003	388	385
France	2003	389	375
China	2003	390	374
Nigeria	2003	391	379
Canada	2003	392	373
North Korea	2003	393	380
Australia	2003	394	371
Norway	2003	395	381
Germany	2003	396	376
Japan	2003	397	378
South Korea	2006	398	409
Spain	2006	399	410
United States	2006	400	417
Trinidad and Tobago	2006	401	414
Ukraine	2006	402	416
Czech Republic	2006	403	392
France	2006	404	395
Ghana	2006	405	397
England	2006	406	394
Angola	2006	407	386
Costa Rica	2006	408	390
Australia	2006	409	388
Iran	2006	410	398
Poland	2006	411	405
Germany	2006	412	396
Croatia	2006	413	391
Switzerland	2006	414	412
Mexico	2006	415	402
Sweden	2006	416	411
Tunisia	2006	417	415
Italy	2006	418	399
Ivory Coast	2006	419	400
Saudi Arabia	2006	420	407
Brazil	2006	421	389
Argentina	2006	422	387
Serbia and Montenegro	2006	423	408
Togo	2006	424	413
Paraguay	2006	425	404
Portugal	2006	426	406
Ecuador	2006	427	393
Netherlands	2006	428	403
Japan	2006	429	401
Brazil	2007	430	420
Norway	2007	431	431
Argentina	2007	432	418
Sweden	2007	433	432
China	2007	434	422
Nigeria	2007	435	429
Denmark	2007	436	423
New Zealand	2007	437	428
North Korea	2007	438	430
Germany	2007	439	425
Japan	2007	440	427
Ghana	2007	441	426
Canada	2007	442	421
England	2007	443	424
United States	2007	444	433
Australia	2007	445	419
Mexico	2010	446	450
Serbia	2010	447	457
Chile	2010	448	439
United States	2010	449	464
England	2010	450	441
Spain	2010	451	462
France	2010	452	442
Brazil	2010	453	437
Ivory Coast	2010	454	448
New Zealand	2010	455	452
Switzerland	2010	456	463
South Korea	2010	457	461
Slovenia	2010	458	459
North Korea	2010	459	454
Nigeria	2010	460	453
Cameroon	2010	461	438
Italy	2010	462	447
Germany	2010	463	443
Argentina	2010	464	435
Paraguay	2010	465	455
Japan	2010	466	449
Denmark	2010	467	440
South Africa	2010	468	460
Portugal	2010	469	456
Ghana	2010	470	444
Greece	2010	471	445
Honduras	2010	472	446
Algeria	2010	473	434
Uruguay	2010	474	465
Netherlands	2010	475	451
Australia	2010	476	436
Slovakia	2010	477	458
France	2011	478	472
Mexico	2011	479	475
Sweden	2011	480	480
Equatorial Guinea	2011	481	471
New Zealand	2011	482	476
North Korea	2011	483	478
Norway	2011	484	479
Brazil	2011	485	467
Canada	2011	486	468
Germany	2011	487	473
England	2011	488	470
Colombia	2011	489	469
Japan	2011	490	474
Australia	2011	491	466
United States	2011	492	481
Nigeria	2011	493	477
Ghana	2014	494	497
Portugal	2014	495	507
Russia	2014	496	508
Spain	2014	497	510
France	2014	498	495
Cameroon	2014	499	488
Algeria	2014	500	482
Mexico	2014	501	504
Switzerland	2014	502	511
England	2014	503	494
South Korea	2014	504	509
Nigeria	2014	505	506
United States	2014	506	512
Croatia	2014	507	492
Ivory Coast	2014	508	502
Germany	2014	509	496
Colombia	2014	510	490
Costa Rica	2014	511	491
Australia	2014	512	484
Italy	2014	513	501
Iran	2014	514	500
Ecuador	2014	515	493
Argentina	2014	516	483
Chile	2014	517	489
Greece	2014	518	498
Brazil	2014	519	487
Honduras	2014	520	499
Bosnia and Herzegovina	2014	521	486
Uruguay	2014	522	513
Netherlands	2014	523	505
Belgium	2014	524	485
Japan	2014	525	503
Ecuador	2015	526	521
France	2015	527	523
Mexico	2015	528	527
United States	2015	529	537
Cameroon	2015	530	516
China	2015	531	518
Canada	2015	532	517
Germany	2015	533	524
Nigeria	2015	534	530
Norway	2015	535	531
Spain	2015	536	533
New Zealand	2015	537	529
Netherlands	2015	538	528
England	2015	539	522
Japan	2015	540	526
Thailand	2015	541	536
Australia	2015	542	514
Sweden	2015	543	534
Colombia	2015	544	519
Ivory Coast	2015	545	525
Brazil	2015	546	515
Costa Rica	2015	547	520
Switzerland	2015	548	535
South Korea	2015	549	532
Sweden	2018	550	566
Russia	2018	551	560
Senegal	2018	552	562
Egypt	2018	553	546
Croatia	2018	554	544
France	2018	555	548
Peru	2018	556	557
Panama	2018	557	556
Iceland	2018	558	550
Denmark	2018	559	545
Spain	2018	560	565
Serbia	2018	561	563
Germany	2018	562	549
Tunisia	2018	563	568
Belgium	2018	564	540
Poland	2018	565	558
Japan	2018	566	552
Mexico	2018	567	553
Colombia	2018	568	542
Switzerland	2018	569	567
Saudi Arabia	2018	570	561
Iran	2018	571	551
Costa Rica	2018	572	543
Morocco	2018	573	554
Nigeria	2018	574	555
Argentina	2018	575	538
Portugal	2018	576	559
South Korea	2018	577	564
England	2018	578	547
Uruguay	2018	579	569
Brazil	2018	580	541
Australia	2018	581	539
Italy	2019	582	580
Argentina	2019	583	570
Nigeria	2019	584	585
France	2019	585	578
Cameroon	2019	586	573
South Africa	2019	587	588
United States	2019	588	593
Sweden	2019	589	591
Canada	2019	590	574
China	2019	591	576
Scotland	2019	592	587
Chile	2019	593	575
Jamaica	2019	594	581
Australia	2019	595	571
England	2019	596	577
New Zealand	2019	597	584
Norway	2019	598	586
Thailand	2019	599	592
Japan	2019	600	582
Brazil	2019	601	572
Spain	2019	602	590
Germany	2019	603	579
Netherlands	2019	604	583
South Korea	2019	605	589
Ghana	2022	606	607
Ecuador	2022	607	603
Uruguay	2022	608	624
Australia	2022	609	595
South Korea	2022	610	619
United States	2022	611	623
Senegal	2022	612	617
Croatia	2022	613	601
France	2022	614	605
Spain	2022	615	620
Germany	2022	616	606
Canada	2022	617	599
Denmark	2022	618	602
Tunisia	2022	619	622
Belgium	2022	620	596
Mexico	2022	621	610
Poland	2022	622	613
Japan	2022	623	609
Wales	2022	624	625
Iran	2022	625	608
Morocco	2022	626	611
Saudi Arabia	2022	627	616
Qatar	2022	628	615
Portugal	2022	629	614
Argentina	2022	630	594
Cameroon	2022	631	598
England	2022	632	604
Serbia	2022	633	618
Costa Rica	2022	634	600
Brazil	2022	635	597
Netherlands	2022	636	612
Switzerland	2022	637	621
\.


--
-- Data for Name: faute; Type: TABLE DATA; Schema: public; Owner: wcuser
--

COPY public.faute (faute_id, joueur_id, match_id, typefaute, faute_minute) FROM stdin;
1	33189	201	jaune	30
2	43733	201	jaune	31
3	52906	201	jaune	34
4	64553	201	jaune	60
5	70408	201	jaune	72
6	20172	206	jaune	56
7	4354	207	jaune	31
8	41601	211	jaune	82
9	25708	211	jaune	82
10	54377	213	jaune	13
11	60582	213	jaune	33
12	8268	213	jaune	45
13	10096	213	jaune	57
14	8449	214	jaune	38
15	61494	214	jaune	72
16	87631	214	jaune	89
17	88728	215	jaune	30
18	98262	217	jaune	90
19	26224	219	jaune	44
20	61942	219	jaune	78
21	94646	221	jaune	15
22	7812	221	jaune	19
23	64553	221	jaune	29
24	98745	221	jaune	29
25	42364	221	jaune	62
26	87631	222	jaune	62
27	92635	222	jaune	67
28	92154	222	jaune	90
29	49133	223	jaune	78
30	62214	226	jaune	67
31	83747	227	jaune	9
32	83931	227	jaune	17
33	33189	227	jaune	32
34	63224	227	jaune	59
35	17002	227	jaune	76
36	2102	227	jaune	118
37	88728	228	jaune	10
38	72441	228	jaune	18
39	50162	229	jaune	5
40	48169	229	jaune	18
41	40429	229	jaune	37
42	25829	229	jaune	44
43	45085	230	jaune	38
44	60896	230	jaune	53
45	72441	230	jaune	66
46	73673	230	jaune	73
47	77530	230	jaune	103
48	67671	230	jaune	114
49	86015	231	jaune	64
50	63224	231	jaune	89
51	42540	232	jaune	27
52	85778	232	jaune	33
53	26214	233	jaune	17
54	67954	233	jaune	49
55	57208	234	rouge	13
56	34664	234	jaune	47
57	51910	234	jaune	59
58	57266	235	jaune	32
59	53970	235	jaune	58
60	12102	235	jaune	61
61	49087	236	jaune	40
62	87058	236	jaune	48
63	11707	238	jaune	25
64	34358	238	jaune	50
65	32274	238	jaune	65
66	83931	238	rouge	69
67	28084	239	jaune	65
68	94783	240	jaune	21
69	33365	240	jaune	47
70	54736	242	jaune	56
71	27772	242	jaune	60
72	12102	242	jaune	65
73	85778	243	jaune	35
74	81415	243	jaune	81
75	89772	243	jaune	87
76	88955	244	rouge	22
77	262	244	jaune	54
78	76230	245	jaune	9
79	99710	245	jaune	44
80	29454	246	jaune	36
81	61494	246	jaune	68
82	89554	246	jaune	72
83	90911	246	jaune	74
84	37575	246	jaune	86
85	12030	247	jaune	48
86	33365	247	jaune	54
87	28084	248	jaune	71
88	6541	249	rouge	37
89	26214	250	jaune	21
90	20553	250	jaune	55
91	22480	250	jaune	60
92	47050	250	jaune	70
93	74389	250	jaune	70
94	1779	251	jaune	77
95	99200	251	jaune	78
96	27040	252	jaune	27
97	79032	252	jaune	81
98	87788	252	jaune	84
99	89311	253	jaune	5
100	65100	253	jaune	22
101	50564	253	jaune	29
102	75999	253	jaune	44
103	4554	253	jaune	67
104	50198	254	jaune	21
105	33365	255	jaune	26
106	82218	255	jaune	60
107	16092	255	jaune	85
108	97548	256	jaune	25
109	92154	256	jaune	71
110	39234	256	jaune	84
111	60896	257	jaune	16
112	69695	257	jaune	35
113	47694	257	jaune	36
114	262	257	jaune	61
115	73193	258	jaune	11
116	77430	258	jaune	27
117	7188	258	jaune	28
118	89519	258	jaune	75
119	91963	258	jaune	84
120	16991	259	jaune	22
121	94783	259	jaune	35
122	45370	259	jaune	58
123	92867	260	jaune	44
124	95634	260	jaune	49
125	4739	261	jaune	72
126	37575	264	jaune	45
127	27040	266	jaune	23
128	56518	266	jaune	68
129	45370	267	jaune	29
130	87744	267	rouge	29
131	72683	267	jaune	37
132	89772	267	jaune	44
133	89554	267	jaune	69
134	20553	268	jaune	26
135	80725	268	jaune	86
136	97548	269	jaune	71
137	77430	269	jaune	76
138	69695	270	jaune	4
139	65100	270	jaune	23
140	16991	270	jaune	40
141	50564	270	jaune	45
142	93788	272	jaune	35
143	8939	272	jaune	60
144	48925	272	jaune	81
145	34326	274	jaune	21
146	86777	274	jaune	48
147	80376	274	jaune	77
148	86777	274	rouge	88
149	34326	274	rouge	89
150	3989	276	jaune	74
151	69644	276	jaune	87
152	72529	278	jaune	19
153	12183	279	jaune	26
154	70353	279	jaune	64
155	41102	281	jaune	43
156	84173	281	jaune	44
157	74565	282	jaune	88
158	15195	284	jaune	60
159	25337	285	jaune	25
160	12467	289	jaune	68
161	95747	289	jaune	87
162	12030	290	jaune	60
163	59590	292	jaune	39
164	16479	294	jaune	35
165	56499	298	jaune	75
166	99593	298	jaune	80
167	32373	299	jaune	7
168	95634	299	jaune	59
169	3652	299	jaune	75
170	7978	299	jaune	89
171	48712	301	jaune	6
172	14080	301	jaune	84
173	48111	301	rouge	87
174	3451	303	jaune	69
175	64134	303	jaune	69
176	47233	303	jaune	85
177	89554	304	jaune	35
178	12030	304	jaune	40
179	1582	304	jaune	50
180	3775	304	jaune	65
181	93788	304	jaune	70
182	48382	307	jaune	35
183	99975	307	jaune	44
184	21248	307	jaune	72
185	31830	308	jaune	15
186	66254	308	jaune	40
187	23168	308	jaune	93
188	45370	308	jaune	94
189	3270	308	jaune	96
190	7663	309	jaune	50
191	61157	309	jaune	55
192	6193	310	jaune	2
193	3652	310	jaune	12
194	99788	310	jaune	47
195	95667	312	jaune	80
196	99185	313	jaune	32
197	34326	313	jaune	74
198	89949	315	jaune	57
199	45774	315	jaune	83
200	49962	316	jaune	34
201	32042	318	jaune	12
202	93218	318	jaune	29
203	31109	318	jaune	66
204	62599	320	jaune	62
205	93788	321	jaune	52
206	32834	321	jaune	76
207	98924	324	jaune	34
208	18610	324	jaune	40
209	58080	324	jaune	80
210	86679	325	jaune	17
211	47601	325	jaune	74
212	26922	327	jaune	11
213	3126	327	jaune	29
214	54028	328	jaune	40
215	17336	329	jaune	35
216	67521	329	jaune	78
217	92317	329	jaune	80
218	19020	329	jaune	87
219	63564	330	jaune	67
220	88607	331	jaune	30
221	69834	331	jaune	68
222	20299	331	jaune	85
223	72529	333	jaune	31
224	84816	334	jaune	65
225	86900	334	jaune	79
226	91562	335	jaune	5
227	88467	336	jaune	36
228	59682	336	jaune	36
229	86679	337	jaune	20
230	41807	337	jaune	26
231	6976	337	jaune	31
232	99593	337	jaune	44
233	98609	337	jaune	45
234	43905	339	jaune	88
235	69834	340	jaune	47
236	19209	340	jaune	75
237	95927	340	rouge	87
238	85024	341	jaune	81
239	33765	341	jaune	85
240	6989	341	rouge	89
241	43037	342	jaune	32
242	99989	342	jaune	74
243	83210	343	jaune	43
244	71779	343	jaune	44
245	3571	344	jaune	20
246	76882	344	jaune	41
247	32829	344	jaune	42
248	40771	344	rouge	60
249	61365	345	jaune	60
250	57931	346	jaune	48
251	91717	347	jaune	15
252	35082	347	jaune	32
253	80404	347	jaune	35
254	66254	347	jaune	39
255	21248	347	jaune	43
256	99593	347	rouge	84
257	45695	348	jaune	68
258	96650	349	jaune	86
259	64968	350	jaune	77
260	80376	351	jaune	33
261	60866	351	jaune	77
262	80404	351	rouge	85
263	35736	351	jaune	85
264	22433	352	jaune	9
265	52461	352	jaune	10
266	96996	352	jaune	83
267	79689	352	jaune	84
268	70703	352	jaune	84
269	76592	353	jaune	57
270	76882	353	jaune	59
271	66593	354	jaune	38
272	40684	354	jaune	65
273	10493	354	jaune	87
274	3652	354	jaune	88
275	47456	354	jaune	90
276	21248	355	jaune	13
277	75736	355	jaune	78
278	34141	356	jaune	15
279	1165	357	jaune	43
280	48883	357	jaune	51
281	57931	357	jaune	57
282	30672	357	jaune	57
283	79617	358	jaune	35
284	5511	358	jaune	40
285	31123	358	jaune	46
286	40684	359	jaune	62
287	22126	359	jaune	71
288	6095	359	jaune	79
289	66365	360	jaune	31
290	29426	360	jaune	61
291	75736	360	jaune	73
292	45695	360	jaune	73
293	89975	360	jaune	88
294	29143	361	jaune	48
295	62546	361	jaune	51
296	3775	361	jaune	64
297	70569	362	jaune	4
298	90842	362	jaune	82
299	64475	364	jaune	44
300	99813	364	jaune	50
301	4834	366	jaune	33
302	26316	367	jaune	23
303	8623	367	jaune	56
304	67053	367	jaune	83
305	63564	368	jaune	36
306	19672	368	jaune	58
307	32829	368	jaune	78
308	62599	368	jaune	79
309	87821	369	jaune	17
310	49962	369	jaune	78
311	97302	369	jaune	88
312	15649	370	jaune	29
313	77194	370	jaune	45
314	29429	371	jaune	28
315	66014	371	jaune	62
316	77330	372	jaune	84
317	29143	373	jaune	54
318	49676	373	jaune	58
319	69165	373	jaune	65
320	16126	374	jaune	30
321	10855	374	jaune	33
322	643	374	jaune	40
323	69834	374	jaune	43
324	95664	375	jaune	31
325	32755	375	jaune	49
326	46375	375	jaune	60
327	5935	376	rouge	52
328	97018	376	jaune	83
329	34141	378	rouge	40
330	92676	378	jaune	50
331	65174	378	jaune	69
332	21024	378	jaune	76
333	97522	379	jaune	5
334	66199	379	jaune	26
335	77194	379	jaune	30
336	26316	379	jaune	75
337	47178	379	jaune	80
338	91970	380	jaune	50
339	76882	380	jaune	85
340	22126	381	jaune	46
341	17582	381	jaune	89
342	47038	382	jaune	16
343	20424	382	jaune	20
344	62944	382	jaune	29
345	97678	382	jaune	42
346	15649	382	jaune	48
347	76810	382	rouge	52
348	72587	382	jaune	65
349	56094	383	jaune	30
350	65888	383	jaune	44
351	64688	383	jaune	74
352	62631	384	jaune	7
353	89543	384	rouge	13
354	94995	384	jaune	35
355	29650	385	jaune	41
356	99991	385	jaune	69
357	22755	387	jaune	25
358	95664	388	jaune	17
359	49669	388	jaune	31
360	43950	388	jaune	35
361	99788	388	jaune	65
362	73911	388	jaune	70
363	46375	388	jaune	71
364	34556	389	jaune	30
365	8949	389	jaune	73
366	73704	390	jaune	55
367	25456	390	jaune	55
368	87821	391	jaune	52
369	31762	392	jaune	64
370	45774	393	jaune	33
371	93792	393	jaune	89
372	40771	394	jaune	12
373	445	395	rouge	36
374	36201	395	jaune	48
375	91180	395	jaune	51
376	57952	396	rouge	1
377	18562	396	jaune	32
378	12472	396	jaune	48
379	36038	396	jaune	62
380	29429	396	jaune	72
381	22385	396	jaune	87
382	86608	397	jaune	58
383	88903	398	jaune	65
384	17582	399	jaune	13
385	3652	399	jaune	30
386	57931	399	jaune	32
387	90635	399	jaune	36
388	12950	399	jaune	83
389	69165	400	jaune	30
390	36582	400	jaune	35
391	62815	400	jaune	49
392	48167	400	jaune	58
393	37351	400	jaune	68
394	15637	400	jaune	83
395	94995	400	jaune	85
396	32608	401	jaune	16
397	29650	401	jaune	40
398	69913	401	jaune	67
399	40516	402	jaune	29
400	92676	402	jaune	65
401	29522	403	jaune	37
402	56811	403	jaune	60
403	78807	403	jaune	67
404	4488	404	jaune	26
405	93792	404	jaune	27
406	96996	404	jaune	32
407	6498	404	jaune	60
408	59792	406	rouge	20
409	95392	406	jaune	27
410	28996	406	jaune	27
411	27251	406	jaune	56
412	59388	406	rouge	65
413	10537	406	jaune	75
414	89412	406	jaune	83
415	49502	406	jaune	86
416	26316	406	jaune	94
417	87821	407	jaune	9
418	22408	407	jaune	60
419	95299	408	jaune	24
420	72141	408	jaune	39
421	14296	408	jaune	44
422	99499	408	jaune	115
423	79344	409	jaune	59
424	643	409	jaune	89
425	24703	410	jaune	27
426	2464	410	jaune	33
427	84816	411	jaune	63
428	80404	412	jaune	17
429	49502	412	jaune	21
430	79689	412	jaune	62
431	46907	412	jaune	77
432	70033	412	jaune	81
433	15637	412	jaune	85
434	31657	413	rouge	9
435	53341	413	jaune	23
436	82949	413	jaune	27
437	12458	413	jaune	54
438	84420	413	rouge	61
439	56334	414	jaune	11
440	1137	414	jaune	44
441	27206	415	jaune	5
442	50458	415	jaune	55
443	99834	415	jaune	70
444	46897	416	jaune	6
445	16313	417	jaune	30
446	43736	417	jaune	39
447	28361	417	jaune	43
448	67232	417	rouge	52
449	40265	417	jaune	61
450	62375	418	jaune	38
451	90842	418	jaune	60
452	71492	418	jaune	83
453	32466	418	jaune	88
454	67713	419	jaune	5
455	27404	421	jaune	75
456	51349	422	jaune	39
457	53055	423	jaune	55
458	11241	423	jaune	58
459	69960	424	jaune	10
460	80363	424	jaune	23
461	81270	424	jaune	70
462	36582	424	jaune	80
463	64968	425	rouge	48
464	5885	425	jaune	51
465	80379	425	jaune	55
466	35873	425	jaune	57
467	80404	425	jaune	70
468	31161	425	jaune	77
469	56577	426	jaune	20
470	99719	426	jaune	44
471	95667	426	jaune	68
472	93318	427	jaune	86
473	85296	428	jaune	62
474	47366	428	jaune	69
475	57468	429	jaune	22
476	85306	429	jaune	52
477	16313	429	jaune	62
478	69681	429	jaune	71
479	46006	429	jaune	85
480	50458	430	jaune	26
481	16899	430	jaune	30
482	67713	430	jaune	31
483	1259	431	jaune	16
484	16382	431	jaune	59
485	26340	431	jaune	88
486	62375	431	jaune	90
487	92339	432	jaune	59
488	95626	432	jaune	65
489	24199	434	jaune	51
490	42749	434	jaune	72
491	73390	435	rouge	35
492	68611	435	jaune	40
493	43076	436	jaune	29
494	99575	436	jaune	52
495	76411	436	jaune	69
496	1137	437	jaune	4
497	30739	437	jaune	8
498	86528	437	jaune	32
499	80379	437	jaune	72
500	22408	437	jaune	86
501	84420	438	jaune	61
502	58080	438	jaune	66
503	10906	438	jaune	75
504	43980	439	jaune	15
505	31825	439	jaune	30
506	10890	439	jaune	38
507	59388	439	jaune	63
508	71107	440	jaune	20
509	23285	440	jaune	36
510	48922	440	jaune	71
511	31892	440	jaune	76
512	23285	440	rouge	76
513	69681	441	jaune	21
514	82723	441	jaune	26
515	85296	441	jaune	28
516	57468	441	jaune	31
517	67942	441	rouge	33
518	93627	441	jaune	42
519	67426	441	jaune	50
520	51936	441	jaune	58
521	29893	441	jaune	84
522	57682	441	jaune	90
523	52500	442	jaune	26
524	71260	442	jaune	30
525	78756	442	jaune	44
526	67585	442	jaune	70
527	17223	443	jaune	5
528	10435	443	jaune	8
529	67329	444	jaune	20
530	16382	444	jaune	28
531	37790	444	jaune	53
532	63692	444	jaune	74
533	86017	446	jaune	22
534	68471	446	jaune	23
535	53299	446	jaune	44
536	99575	446	rouge	49
537	35322	446	jaune	62
538	62193	447	jaune	38
539	41175	447	jaune	47
540	18335	447	jaune	85
541	92391	448	jaune	43
542	84420	449	jaune	44
543	53341	449	jaune	47
544	12458	449	jaune	68
545	92695	449	jaune	72
546	31825	449	jaune	74
547	56577	449	jaune	117
548	74237	450	jaune	6
549	73737	450	jaune	53
550	57995	450	jaune	56
551	20647	450	jaune	68
552	37790	450	jaune	75
553	31161	451	jaune	27
554	49676	451	jaune	28
555	61247	451	jaune	40
556	6573	451	jaune	50
557	88506	451	rouge	85
558	34056	451	jaune	87
559	4572	452	rouge	21
560	92391	452	rouge	21
561	50869	452	jaune	32
562	76874	452	jaune	72
563	49502	452	jaune	77
564	42603	453	jaune	17
565	96122	453	jaune	108
566	30739	453	jaune	111
567	49988	453	jaune	114
568	2668	454	jaune	14
569	22385	454	jaune	26
570	69960	454	jaune	35
571	67585	454	jaune	36
572	86817	454	jaune	65
573	54317	455	jaune	7
574	83693	455	jaune	60
575	61508	455	jaune	92
576	9094	455	jaune	97
577	31693	455	jaune	110
578	6127	456	jaune	85
579	80379	457	jaune	21
580	48922	457	rouge	24
581	46907	457	jaune	41
582	30977	457	jaune	61
583	14628	457	jaune	111
584	35719	458	jaune	36
585	15882	458	jaune	43
586	85306	459	rouge	11
587	8239	459	jaune	14
588	91373	459	jaune	28
589	20647	459	jaune	38
590	65434	459	jaune	88
591	31657	460	jaune	28
592	67307	460	jaune	70
593	95667	460	jaune	104
594	58080	460	jaune	120
595	75545	461	jaune	22
596	49676	461	rouge	30
597	79080	461	jaune	71
598	46907	461	jaune	76
599	35873	461	jaune	82
600	22408	461	jaune	118
601	96960	462	jaune	66
602	6127	462	jaune	99
603	67713	462	jaune	109
604	53936	464	rouge	5
605	4572	464	jaune	52
606	31161	464	rouge	65
607	30977	464	jaune	84
608	80404	464	jaune	87
609	48120	468	jaune	58
610	41343	468	jaune	67
611	21261	468	jaune	79
612	28901	469	jaune	24
613	57215	469	jaune	64
614	12901	470	jaune	59
615	58688	471	jaune	34
616	24476	472	jaune	75
617	24862	473	jaune	50
618	18032	474	jaune	70
619	85493	475	jaune	55
620	56906	478	jaune	31
621	58688	480	jaune	30
622	36817	480	jaune	33
623	54286	481	rouge	6
624	32241	481	jaune	48
625	65393	482	jaune	50
626	51730	482	jaune	50
627	43536	483	jaune	17
628	63276	483	jaune	37
629	65510	483	jaune	70
630	8153	484	jaune	39
631	57215	484	jaune	57
632	81571	484	jaune	58
633	84060	484	jaune	66
634	10951	485	jaune	20
635	84389	485	jaune	97
636	54832	486	jaune	23
637	44228	488	jaune	59
638	54794	488	jaune	67
639	98080	489	jaune	53
640	81571	489	jaune	60
641	54794	490	jaune	54
642	83968	491	jaune	6
643	61814	491	jaune	37
644	84079	491	jaune	39
645	37963	491	jaune	54
646	92800	491	jaune	66
647	22812	491	rouge	83
648	74977	491	jaune	89
649	38878	492	jaune	24
650	3307	492	rouge	25
651	95664	492	jaune	37
652	51868	492	jaune	61
653	97666	492	jaune	83
654	94830	493	jaune	26
655	76790	493	jaune	82
656	14008	493	jaune	89
657	99685	494	jaune	30
658	90357	494	jaune	50
659	25274	494	jaune	80
660	43980	495	jaune	36
661	69340	495	jaune	39
662	49600	495	jaune	53
663	10890	495	jaune	70
664	96824	496	jaune	23
665	8730	496	jaune	26
666	99499	496	jaune	81
667	83199	496	jaune	85
668	84885	496	jaune	89
669	93679	497	jaune	16
670	61579	497	jaune	26
671	78308	497	jaune	62
672	12458	498	jaune	5
673	63429	498	jaune	72
674	70700	499	jaune	61
675	69635	499	jaune	65
676	82492	499	jaune	78
677	60332	500	jaune	28
678	29132	500	jaune	31
679	49163	500	jaune	36
680	21550	500	jaune	61
681	32212	500	jaune	75
682	6459	501	jaune	25
683	41616	501	jaune	40
684	43850	501	jaune	55
685	18314	502	jaune	15
686	24945	502	jaune	38
687	35246	502	jaune	53
688	61872	502	jaune	70
689	19567	503	jaune	54
690	22820	503	jaune	73
691	81047	504	jaune	32
692	86528	504	jaune	40
693	43639	504	jaune	47
694	15773	504	rouge	73
695	23692	505	jaune	24
696	79863	505	jaune	48
697	88002	506	rouge	21
698	52878	506	jaune	32
699	26730	506	jaune	34
700	93679	506	jaune	68
701	49642	507	jaune	22
702	26034	507	rouge	22
703	84079	507	jaune	32
704	39863	507	jaune	38
705	97902	507	jaune	62
706	92215	507	jaune	89
707	25274	508	jaune	26
708	97610	508	jaune	45
709	50787	508	jaune	57
710	99685	508	jaune	70
711	8703	509	jaune	8
712	7520	509	jaune	37
713	12551	509	jaune	44
714	98173	509	rouge	63
715	6372	510	rouge	1
716	54805	510	jaune	34
717	60371	510	jaune	42
718	63692	510	jaune	52
719	63429	510	jaune	58
720	50869	511	jaune	19
721	10129	511	jaune	20
722	27957	511	jaune	39
723	51357	511	jaune	49
724	92391	511	jaune	81
725	22409	511	jaune	88
726	19991	512	jaune	34
727	75079	512	jaune	50
728	21550	512	jaune	75
729	78753	512	jaune	78
730	96824	512	jaune	83
731	12996	512	jaune	90
732	39450	513	jaune	20
733	74911	513	jaune	53
734	35873	513	jaune	54
735	98623	514	jaune	6
736	7517	514	jaune	17
737	47670	514	jaune	26
738	56496	514	jaune	33
739	38731	514	jaune	42
740	12695	514	jaune	59
741	35810	514	jaune	70
742	40793	514	jaune	84
743	1678	515	jaune	39
744	42991	515	jaune	58
745	49600	515	jaune	62
746	10890	515	jaune	80
747	26437	515	jaune	85
748	14008	516	jaune	41
749	34393	516	jaune	48
750	69340	516	jaune	62
751	12625	516	jaune	73
752	59647	517	jaune	46
753	97666	517	jaune	90
754	67713	518	jaune	24
755	91373	518	jaune	28
756	61872	518	jaune	44
757	51868	518	jaune	89
758	97610	519	jaune	25
759	87231	519	jaune	33
760	46904	519	jaune	63
761	21495	519	jaune	66
762	91106	520	jaune	3
763	95491	520	jaune	29
764	63024	520	jaune	36
765	2163	520	jaune	45
766	7683	520	jaune	83
767	84420	521	jaune	12
768	93402	521	jaune	44
769	48249	521	jaune	57
770	69635	521	jaune	87
771	70700	521	jaune	90
772	56505	522	jaune	23
773	66178	522	jaune	83
774	51472	523	jaune	3
775	97414	523	jaune	61
776	60814	523	jaune	77
777	61846	523	jaune	80
778	89133	524	jaune	12
779	82124	524	jaune	14
780	91608	524	jaune	25
781	48036	524	jaune	28
782	16451	524	jaune	41
783	50869	524	jaune	75
784	61116	524	jaune	79
785	81648	525	jaune	7
786	56496	525	jaune	24
787	79080	525	jaune	34
788	27629	525	jaune	44
789	6964	525	rouge	45
790	47670	525	jaune	58
791	22562	525	jaune	74
792	84542	525	jaune	81
793	12695	526	jaune	32
794	59135	526	jaune	41
795	41790	526	jaune	66
796	46986	526	jaune	70
797	87830	527	jaune	13
798	68490	527	jaune	37
799	43307	527	jaune	38
800	619	528	jaune	18
801	59647	528	jaune	19
802	80697	528	jaune	22
803	6183	528	jaune	23
804	82747	528	jaune	69
805	76790	528	jaune	77
806	9954	528	jaune	85
807	20256	528	jaune	87
808	75066	529	jaune	16
809	92339	529	jaune	67
810	78753	529	jaune	71
811	23360	529	jaune	74
812	79080	530	jaune	33
813	19537	530	jaune	50
814	78898	530	jaune	55
815	28816	530	jaune	56
816	79864	530	jaune	68
817	41616	530	jaune	83
818	54322	530	jaune	84
819	72919	531	jaune	72
820	78793	532	jaune	8
821	26340	532	jaune	16
822	72471	532	rouge	43
823	7720	532	jaune	43
824	82723	532	jaune	49
825	34393	532	rouge	64
826	8863	532	jaune	80
827	74911	533	jaune	2
828	31072	533	jaune	6
829	36036	533	jaune	29
830	56969	533	jaune	41
831	41790	533	jaune	53
832	91949	533	jaune	58
833	32071	533	jaune	60
834	52474	533	jaune	62
835	78280	533	rouge	75
836	43222	533	jaune	80
837	88510	534	rouge	12
838	78308	534	jaune	14
839	5061	534	jaune	17
840	46904	534	rouge	28
841	48990	534	jaune	34
842	99271	534	jaune	67
843	21741	534	jaune	70
844	21495	534	jaune	76
845	24945	535	jaune	3
846	97666	535	jaune	19
847	42249	536	jaune	40
848	32466	536	jaune	74
849	50869	536	jaune	89
850	87830	537	jaune	14
851	68490	537	jaune	15
852	47670	537	jaune	22
853	77552	537	jaune	49
854	91373	537	jaune	50
855	81648	537	jaune	82
856	94024	537	jaune	85
857	4572	537	jaune	89
858	21234	538	jaune	7
859	19537	538	jaune	21
860	79864	538	jaune	34
861	63692	538	rouge	43
862	11979	538	jaune	108
863	23633	539	jaune	52
864	36036	539	jaune	61
865	19567	539	jaune	65
866	87231	539	jaune	80
867	56496	539	jaune	83
868	12418	540	jaune	3
869	75066	540	jaune	29
870	92339	540	rouge	63
871	26281	540	jaune	86
872	56496	541	jaune	73
873	60371	541	jaune	82
874	78793	542	jaune	4
875	83615	542	jaune	41
876	87231	542	jaune	42
877	91718	542	jaune	87
878	26383	544	jaune	21
879	14897	544	jaune	57
880	16323	544	jaune	75
881	89408	545	jaune	17
882	28260	545	jaune	44
883	19148	545	jaune	77
884	26950	546	jaune	69
885	89903	546	jaune	86
886	77926	547	jaune	25
887	4853	547	jaune	28
888	17776	547	rouge	30
889	19145	547	jaune	37
890	41263	547	jaune	45
891	44067	548	jaune	3
892	14897	549	jaune	10
893	41343	549	jaune	26
894	89192	549	jaune	48
895	10757	550	jaune	14
896	63276	550	jaune	61
897	10791	551	jaune	14
898	62330	551	jaune	44
899	89903	551	jaune	83
900	5714	552	jaune	34
901	74331	552	jaune	54
902	87217	553	jaune	62
903	19145	553	jaune	73
904	2688	553	jaune	79
905	41263	553	jaune	83
906	28901	554	jaune	29
907	89416	554	jaune	38
908	80982	554	jaune	55
909	17759	554	rouge	88
910	47392	554	jaune	89
911	40008	555	rouge	7
912	17405	555	jaune	25
913	1608	555	jaune	30
914	63276	555	jaune	35
915	52478	555	jaune	59
916	97167	555	jaune	62
917	33252	555	jaune	65
918	62310	556	jaune	15
919	436	557	jaune	5
920	85817	557	jaune	68
921	94567	557	jaune	90
922	87029	558	jaune	26
923	26057	558	jaune	36
924	28260	558	jaune	80
925	39552	558	jaune	88
926	71560	559	jaune	56
927	77926	560	jaune	42
928	49668	560	jaune	55
929	72800	560	jaune	82
930	61821	560	jaune	88
931	75727	561	jaune	47
932	62310	561	jaune	72
933	58688	562	jaune	23
934	74955	562	jaune	90
935	17606	563	jaune	57
936	74331	563	jaune	70
937	46333	564	jaune	22
938	10128	564	jaune	77
939	18995	565	jaune	6
940	91065	565	rouge	22
941	78729	566	jaune	52
942	35093	566	jaune	65
943	46333	567	jaune	45
944	27293	568	jaune	2
945	5714	568	jaune	22
946	58688	568	jaune	58
947	29915	568	jaune	70
948	56227	569	jaune	25
949	3658	569	jaune	37
950	56505	569	jaune	47
951	76158	570	jaune	79
952	59777	571	jaune	8
953	88863	571	jaune	31
954	91710	571	jaune	45
955	43934	571	jaune	53
956	79494	571	jaune	66
957	46006	572	jaune	27
958	45873	572	jaune	30
959	16713	573	rouge	27
960	40108	573	jaune	45
961	81648	573	jaune	45
962	47670	573	jaune	73
963	78753	574	jaune	11
964	87412	574	jaune	12
965	77711	574	jaune	60
966	62564	574	jaune	73
967	40400	575	jaune	28
968	94478	575	jaune	39
969	61954	575	jaune	53
970	56430	575	jaune	75
971	61706	576	jaune	56
972	3307	576	jaune	59
973	74808	576	jaune	62
974	22620	576	jaune	75
975	66219	577	jaune	20
976	77010	577	jaune	26
977	21495	577	jaune	27
978	55350	577	rouge	30
979	33618	578	jaune	20
980	17071	578	jaune	29
981	59191	578	rouge	80
982	29629	579	jaune	26
983	36022	579	jaune	67
984	99803	579	jaune	92
985	11960	580	jaune	42
986	93318	580	jaune	60
987	37461	581	jaune	5
988	41724	581	jaune	59
989	36985	581	jaune	62
990	44011	582	jaune	48
991	90120	582	jaune	70
992	41620	582	jaune	87
993	97840	582	jaune	88
994	21571	583	jaune	47
995	48638	583	jaune	54
996	4888	583	jaune	69
997	12625	583	jaune	78
998	65108	584	jaune	30
999	34695	584	jaune	50
1000	35902	584	jaune	77
1001	78998	584	jaune	84
1002	2842	584	jaune	85
1003	39265	585	jaune	24
1004	72296	585	jaune	53
1005	56227	585	jaune	56
1006	25644	585	jaune	58
1007	14349	586	jaune	32
1008	3658	586	jaune	36
1009	76158	586	jaune	64
1010	9547	586	jaune	87
1011	16244	587	jaune	16
1012	77198	587	jaune	26
1013	14852	587	jaune	47
1014	39251	587	jaune	58
1015	82614	587	jaune	74
1016	67168	588	jaune	6
1017	53197	588	jaune	16
1018	36036	588	jaune	26
1019	7520	588	rouge	42
1020	42659	588	jaune	63
1021	6511	588	jaune	79
1022	98173	588	jaune	85
1023	57898	589	jaune	23
1024	10490	589	jaune	28
1025	11000	589	jaune	56
1026	35183	589	jaune	57
1027	65806	589	jaune	63
1028	19030	589	rouge	65
1029	75330	589	rouge	66
1030	56543	589	jaune	73
1031	87412	589	rouge	85
1032	55518	590	jaune	7
1033	44462	590	rouge	19
1034	74952	590	jaune	36
1035	56735	590	jaune	50
1036	56430	590	rouge	71
1037	88041	590	jaune	82
1038	56969	591	jaune	20
1039	74808	591	jaune	44
1040	25715	591	jaune	49
1041	57696	591	jaune	66
1042	83122	591	jaune	70
1043	14982	591	jaune	78
1044	96053	592	jaune	8
1045	34957	592	jaune	30
1046	76678	592	jaune	76
1047	64962	592	jaune	87
1048	62861	593	jaune	26
1049	33594	593	jaune	41
1050	36022	593	jaune	70
1051	75377	593	jaune	70
1052	34956	593	jaune	89
1053	34636	594	rouge	28
1054	21741	594	jaune	39
1055	88428	594	jaune	47
1056	52358	594	rouge	54
1057	86884	594	jaune	68
1058	72495	595	jaune	26
1059	64624	595	jaune	92
1060	49502	596	jaune	75
1061	41974	597	rouge	4
1062	28816	597	jaune	65
1063	49195	597	jaune	88
1064	32369	598	jaune	8
1065	68379	598	jaune	18
1066	65077	598	jaune	77
1067	89154	599	jaune	16
1068	21571	599	jaune	18
1069	44011	599	jaune	83
1070	30739	600	jaune	4
1071	19537	600	jaune	47
1072	16780	600	jaune	78
1073	48638	600	jaune	88
1074	98173	601	rouge	8
1075	91710	601	jaune	50
1076	79494	601	jaune	55
1077	16244	601	jaune	66
1078	38724	601	rouge	88
1079	30572	601	jaune	89
1080	77565	602	jaune	3
1081	28521	602	jaune	35
1082	77198	602	jaune	43
1083	43222	602	jaune	87
1084	66639	602	jaune	88
1085	61579	603	jaune	54
1086	3442	603	jaune	61
1087	189	604	jaune	21
1088	74264	604	rouge	53
1089	78077	604	jaune	81
1090	54985	605	jaune	53
1091	96540	605	jaune	62
1092	90473	605	jaune	65
1093	37132	605	jaune	78
1094	17941	606	jaune	30
1095	2423	606	jaune	38
1096	56543	606	jaune	65
1097	39450	607	jaune	25
1098	72134	607	jaune	38
1099	8700	608	jaune	16
1100	99418	608	jaune	45
1101	60964	608	jaune	73
1102	41316	608	jaune	85
1103	96267	609	jaune	48
1104	10129	609	jaune	65
1105	65241	609	jaune	67
1106	84722	609	jaune	83
1107	66219	609	jaune	83
1108	72763	610	jaune	18
1109	46061	610	jaune	21
1110	92458	610	jaune	46
1111	45941	610	jaune	46
1112	32594	610	jaune	58
1113	50252	610	jaune	68
1114	21741	610	rouge	89
1115	91373	611	jaune	31
1116	77552	611	jaune	45
1117	38371	611	jaune	47
1118	97459	612	jaune	13
1119	22793	612	jaune	41
1120	85140	612	jaune	61
1121	85355	613	jaune	20
1122	65	613	jaune	23
1123	83403	613	jaune	35
1124	37461	613	jaune	43
1125	5779	613	jaune	47
1126	26414	613	jaune	58
1127	65019	613	jaune	68
1128	3376	614	jaune	4
1129	6565	614	jaune	78
1130	61134	614	jaune	88
1131	80178	615	jaune	20
1132	63916	615	jaune	22
1133	76247	615	jaune	86
1134	71020	615	jaune	89
1135	63416	615	jaune	89
1136	22242	616	jaune	28
1137	58711	616	jaune	57
1138	99732	617	jaune	35
1139	69680	617	jaune	38
1140	48934	617	jaune	54
1141	72296	617	jaune	62
1142	42659	617	jaune	84
1143	43222	617	jaune	89
1144	80753	618	jaune	34
1145	72471	618	jaune	45
1146	26025	618	jaune	45
1147	91718	618	jaune	91
1148	36426	619	jaune	19
1149	40108	619	jaune	23
1150	52469	619	jaune	32
1151	76678	619	jaune	84
1152	3217	619	jaune	99
1153	77711	620	jaune	24
1154	83122	620	jaune	49
1155	83522	621	jaune	46
1156	49502	621	jaune	56
1157	83344	621	jaune	57
1158	15678	621	jaune	77
1159	88428	621	jaune	87
1160	35902	621	jaune	88
1161	93318	622	jaune	38
1162	12268	622	jaune	52
1163	80898	622	jaune	73
1164	5779	623	jaune	27
1165	19537	623	jaune	43
1166	12625	623	jaune	70
1167	85355	623	jaune	70
1168	70680	623	jaune	81
1169	13285	624	jaune	5
1170	15550	624	jaune	10
1171	62209	624	jaune	44
1172	6370	624	jaune	47
1173	81049	624	rouge	47
1174	88203	624	jaune	73
1175	81085	624	jaune	120
1176	83836	625	jaune	26
1177	29143	625	jaune	28
1178	26820	625	jaune	53
1179	61954	625	jaune	62
1180	36036	625	jaune	113
1181	85176	626	jaune	11
1182	72404	626	jaune	19
1183	56505	626	jaune	37
1184	90473	626	jaune	39
1185	37132	626	jaune	72
1186	91718	626	jaune	81
1187	46061	627	jaune	10
1188	92458	627	rouge	17
1189	28816	627	jaune	22
1190	82949	627	jaune	60
1191	65	627	rouge	86
1192	41724	628	jaune	13
1193	78998	628	jaune	18
1194	15678	628	jaune	37
1195	53262	628	rouge	40
1196	58374	628	jaune	57
1197	63053	629	jaune	31
1198	3658	629	jaune	45
1199	27926	629	jaune	48
1200	45916	629	jaune	60
1201	88340	629	jaune	90
1202	88946	629	jaune	119
1203	21803	630	jaune	45
1204	74952	630	rouge	74
1205	75377	630	jaune	75
1206	41724	630	jaune	88
1207	76217	631	jaune	34
1208	98512	631	jaune	52
1209	21803	631	jaune	69
1210	75377	631	jaune	74
1211	27957	631	jaune	89
1212	45916	631	jaune	89
1213	9547	632	jaune	33
1214	61954	632	jaune	39
1215	79380	632	rouge	48
1216	28482	632	jaune	56
1217	40400	665	jaune	47
1218	95302	665	jaune	51
1219	15705	666	jaune	30
1220	56778	666	jaune	51
1221	19727	666	jaune	82
1222	7520	666	jaune	89
1223	17321	667	jaune	25
1224	79273	667	jaune	34
1225	27808	667	jaune	51
1226	67544	668	jaune	43
1227	35902	668	jaune	83
1228	90435	668	jaune	91
1229	76131	669	jaune	51
1230	6935	669	jaune	73
1231	6370	669	jaune	90
1232	65611	670	jaune	3
1233	65806	670	jaune	9
1234	50109	670	jaune	35
1235	59298	670	jaune	38
1236	5390	670	jaune	47
1237	82458	670	jaune	65
1238	93337	670	jaune	90
1239	22263	670	jaune	93
1240	97840	671	jaune	12
1241	45212	671	jaune	47
1242	68329	671	jaune	73
1243	76612	672	jaune	36
1244	31903	672	jaune	46
1245	649	672	jaune	65
1246	70100	673	rouge	59
1247	79130	674	jaune	21
1248	78533	674	rouge	24
1249	44850	674	rouge	44
1250	79146	674	jaune	73
1251	59372	675	jaune	14
1252	92146	675	jaune	49
1253	99914	675	jaune	54
1254	88863	675	jaune	81
1255	50749	676	jaune	15
1256	26474	676	jaune	17
1257	28870	676	jaune	60
1258	39905	676	jaune	72
1259	71211	676	jaune	77
1260	55170	676	jaune	79
1261	68890	676	jaune	85
1262	2977	677	jaune	21
1263	79993	677	jaune	31
1264	46807	677	jaune	54
1265	52358	677	jaune	62
1266	71601	677	jaune	82
1267	49007	678	jaune	31
1268	25724	678	jaune	70
1269	53829	678	jaune	79
1270	34709	678	jaune	84
1271	39884	678	jaune	90
1272	65105	679	jaune	27
1273	15858	679	jaune	50
1274	640	679	jaune	75
1275	51792	679	jaune	88
1276	37140	680	jaune	34
1277	92307	680	jaune	52
1278	91976	680	jaune	92
1279	80289	682	jaune	7
1280	62977	682	jaune	10
1281	50534	682	jaune	20
1282	35019	682	rouge	62
1283	72404	682	jaune	82
1284	46718	682	jaune	84
1285	67168	683	jaune	10
1286	683	683	jaune	59
1287	76244	684	jaune	11
1288	51395	684	rouge	25
1289	40400	684	jaune	47
1290	64372	684	jaune	47
1291	3231	684	jaune	48
1292	74863	684	jaune	47
1293	56718	685	jaune	31
1294	42808	685	jaune	69
1295	79669	685	jaune	80
1296	23800	686	jaune	9
1297	76678	686	jaune	44
1298	75108	686	jaune	60
1299	34530	686	jaune	80
1300	84542	687	jaune	13
1301	16557	687	jaune	29
1302	8307	687	jaune	50
1303	56543	688	jaune	12
1304	13966	688	jaune	35
1305	84477	688	jaune	52
1306	99521	688	jaune	59
1307	22187	688	jaune	62
1308	6135	688	jaune	75
1309	61666	689	jaune	39
1310	34670	689	jaune	51
1311	57361	690	jaune	25
1312	66308	690	jaune	69
1313	3128	691	jaune	15
1314	11930	691	jaune	27
1315	32567	691	jaune	49
1316	86943	691	jaune	61
1317	89297	691	jaune	65
1318	19156	691	jaune	87
1319	52032	692	jaune	20
1320	32696	692	jaune	24
1321	73169	692	jaune	43
1322	63089	692	jaune	45
1323	46497	692	jaune	89
1324	76375	693	jaune	13
1325	11915	693	jaune	15
1326	27678	693	jaune	38
1327	95259	693	jaune	42
1328	28437	693	jaune	60
1329	84762	693	jaune	91
1330	34695	694	jaune	30
1331	72797	694	jaune	39
1332	55097	694	jaune	80
1333	15858	695	jaune	22
1334	21070	695	jaune	40
1335	41620	695	jaune	43
1336	82870	695	jaune	68
1337	668	695	jaune	69
1338	34709	696	jaune	21
1339	11424	696	jaune	25
1340	73722	696	jaune	27
1341	61068	696	jaune	31
1342	90321	696	jaune	39
1343	74065	697	jaune	8
1344	46718	697	jaune	27
1345	34389	697	jaune	71
1346	1462	698	jaune	2
1347	27229	698	jaune	4
1348	3231	698	jaune	8
1349	91888	698	jaune	19
1350	76244	698	jaune	35
1351	37924	698	jaune	39
1352	49428	698	jaune	40
1353	82212	698	jaune	69
1354	84943	698	jaune	82
1355	38683	698	jaune	82
1356	62977	698	jaune	87
1357	35489	698	jaune	87
1358	63522	699	jaune	8
1359	45490	699	jaune	9
1360	35902	699	jaune	29
1361	84003	699	jaune	31
1362	57588	699	rouge	37
1363	98173	699	jaune	42
1364	33751	699	jaune	42
1365	60766	699	jaune	44
1366	86465	699	jaune	56
1367	84152	699	jaune	58
1368	99681	699	rouge	60
1369	67544	699	jaune	72
1370	35264	699	jaune	74
1371	38724	699	jaune	81
1372	20886	700	jaune	61
1373	69817	700	jaune	70
1374	35873	702	rouge	47
1375	28816	702	jaune	55
1376	88203	702	jaune	58
1377	59548	702	jaune	65
1378	11130	702	jaune	75
1379	42895	702	jaune	78
1380	42797	703	rouge	4
1381	6135	703	jaune	15
1382	31903	703	jaune	68
1383	30524	703	jaune	69
1384	84477	703	jaune	79
1385	74981	703	rouge	81
1386	72876	704	jaune	16
1387	14062	704	jaune	67
1388	22393	704	jaune	69
1389	65611	704	jaune	81
1390	91718	705	jaune	93
1391	52032	706	jaune	19
1392	46497	706	jaune	30
1393	83943	706	jaune	46
1394	37402	706	rouge	58
1395	12619	706	jaune	62
1396	23883	706	jaune	81
1397	87187	707	jaune	72
1398	99914	707	jaune	86
1399	29621	707	jaune	92
1400	92547	708	jaune	2
1401	88863	708	jaune	5
1402	45258	708	jaune	10
1403	42038	708	jaune	43
1404	42227	708	jaune	55
1405	1311	708	jaune	57
1406	52784	708	jaune	84
1407	27678	709	jaune	12
1408	79578	709	jaune	14
1409	46499	709	jaune	39
1410	51792	709	jaune	64
1411	53680	709	jaune	84
1412	89154	710	jaune	21
1413	10094	710	jaune	81
1414	13151	711	jaune	44
1415	6017	711	jaune	46
1416	93812	711	jaune	63
1417	34695	711	jaune	72
1418	75230	711	jaune	86
1419	37140	712	rouge	22
1420	96267	712	jaune	24
1421	70698	712	rouge	27
1422	56626	712	jaune	57
1423	51785	712	jaune	74
1424	73722	712	jaune	83
1425	26616	712	jaune	93
1426	17884	713	rouge	26
1427	32136	713	jaune	35
1428	98051	713	jaune	50
1429	73157	713	jaune	71
1430	84003	713	jaune	92
1431	37132	714	jaune	24
1432	68164	714	jaune	50
1433	37924	715	jaune	73
1434	91308	715	jaune	94
1435	29082	716	jaune	62
1436	23800	716	jaune	87
1437	35246	716	jaune	89
1438	2842	717	jaune	26
1439	13917	717	jaune	37
1440	58649	717	jaune	47
1441	78068	717	jaune	50
1442	9888	717	jaune	53
1443	45941	717	jaune	67
1444	88428	717	jaune	70
1445	21495	717	jaune	81
1446	76191	717	jaune	83
1447	32594	717	jaune	84
1448	44763	717	rouge	88
1449	46499	718	jaune	24
1450	85176	718	jaune	28
1451	44850	719	jaune	21
1452	65298	719	jaune	44
1453	79993	719	jaune	45
1454	58212	719	jaune	90
1455	15450	720	jaune	4
1456	96267	720	jaune	17
1457	42038	720	rouge	22
1458	26847	720	jaune	55
1459	57378	720	jaune	59
1460	83544	720	jaune	80
1461	22338	720	jaune	99
1462	7865	720	jaune	115
1463	57361	721	rouge	57
1464	63916	721	jaune	75
1465	1249	721	jaune	86
1466	97784	722	jaune	40
1467	2842	722	jaune	41
1468	51287	722	jaune	66
1469	65108	722	jaune	68
1470	97459	722	jaune	68
1471	58649	722	jaune	69
1472	9888	722	jaune	70
1473	75255	723	jaune	52
1474	24963	723	jaune	53
1475	8514	723	jaune	111
1476	27229	724	jaune	12
1477	46497	724	jaune	22
1478	95302	724	jaune	63
1479	41133	724	jaune	87
1480	84003	725	jaune	71
1481	55504	725	jaune	85
1482	66219	725	jaune	90
1483	45956	726	jaune	41
1484	63089	726	jaune	59
1485	23883	726	jaune	90
1486	60562	727	jaune	23
1487	63089	727	jaune	50
1488	61478	727	jaune	83
1489	66308	728	jaune	6
1490	27787	728	jaune	9
1491	556	729	jaune	86
1492	60731	729	jaune	91
1493	93242	730	jaune	22
1494	16375	730	jaune	25
1495	34716	730	jaune	28
1496	49268	730	jaune	71
1497	41105	731	jaune	21
1498	26057	731	jaune	38
1499	15303	731	jaune	46
1500	50598	731	jaune	78
1501	80199	732	jaune	16
1502	23308	732	jaune	18
1503	84467	732	rouge	39
1504	60387	732	jaune	59
1505	17759	733	jaune	13
1506	96012	733	jaune	72
1507	56708	733	jaune	93
1508	19610	734	jaune	2
1509	76840	734	jaune	22
1510	76130	734	jaune	71
1511	90185	735	jaune	83
1512	42830	735	jaune	87
1513	3333	736	jaune	90
1514	31275	737	jaune	51
1515	29694	737	jaune	77
1516	41816	738	jaune	80
1517	63727	739	jaune	37
1518	65913	739	jaune	45
1519	93602	739	jaune	65
1520	37119	739	jaune	83
1521	66491	740	jaune	29
1522	28528	740	jaune	41
1523	35069	740	jaune	62
1524	15381	740	jaune	86
1525	33354	742	jaune	52
1526	23894	742	jaune	56
1527	48897	743	jaune	55
1528	35111	743	jaune	89
1529	72006	743	jaune	91
1530	59238	744	jaune	76
1531	46780	745	jaune	51
1532	24658	745	jaune	72
1533	39878	748	jaune	46
1534	98467	750	jaune	16
1535	89236	750	jaune	22
1536	98699	750	jaune	40
1537	69790	750	jaune	91
1538	47947	751	jaune	52
1539	12997	751	jaune	59
1540	90185	752	jaune	90
1541	56708	753	jaune	15
1542	46780	753	jaune	37
1543	85779	753	jaune	43
1544	11872	753	jaune	52
1545	39183	754	jaune	66
1546	60731	754	jaune	75
1547	72974	754	jaune	80
1548	84389	754	jaune	86
1549	8789	755	jaune	66
1550	20854	756	jaune	42
1551	87255	756	jaune	53
1552	26057	756	jaune	76
1553	14537	756	jaune	92
1554	84530	758	jaune	64
1555	20854	759	jaune	65
1556	26057	759	jaune	76
1557	30163	761	jaune	30
1558	98031	762	jaune	31
1559	95900	762	jaune	37
1560	42534	762	jaune	70
1561	62157	763	jaune	19
1562	71995	763	jaune	22
1563	77532	763	jaune	63
1564	86728	764	rouge	15
1565	94201	764	jaune	74
1566	42895	764	jaune	90
1567	38901	765	jaune	41
1568	64352	765	jaune	48
1569	92316	765	jaune	62
1570	48161	765	jaune	81
1571	99466	765	jaune	91
1572	22793	766	jaune	34
1573	21832	766	jaune	56
1574	50012	766	jaune	64
1575	50226	766	jaune	81
1576	28832	766	jaune	85
1577	41962	766	jaune	90
1578	89297	767	jaune	18
1579	59901	767	jaune	55
1580	97434	767	jaune	91
1581	70442	768	jaune	26
1582	61845	768	jaune	28
1583	3457	768	jaune	48
1584	88171	768	jaune	52
1585	62437	768	jaune	79
1586	11915	769	jaune	31
1587	63129	769	jaune	33
1588	56897	769	jaune	40
1589	66908	769	jaune	58
1590	65411	769	jaune	68
1591	44926	769	jaune	69
1592	59039	769	jaune	78
1593	87765	770	jaune	5
1594	54533	770	jaune	16
1595	36056	770	jaune	59
1596	97459	770	jaune	60
1597	29090	770	jaune	81
1598	86056	770	jaune	88
1599	65802	771	jaune	10
1600	50641	771	jaune	41
1601	22378	771	jaune	62
1602	38556	771	jaune	65
1603	38599	771	jaune	88
1604	3523	772	rouge	23
1605	80410	772	jaune	24
1606	94594	772	jaune	41
1607	22338	772	jaune	51
1608	8365	772	jaune	92
1609	82814	773	jaune	42
1610	87221	773	jaune	45
1611	10789	773	jaune	56
1612	4469	773	jaune	64
1613	56430	773	jaune	72
1614	11817	773	jaune	72
1615	23315	773	jaune	93
1616	61684	773	jaune	93
1617	84378	774	jaune	32
1618	52008	774	jaune	42
1619	61666	774	jaune	67
1620	42144	774	jaune	90
1621	7368	775	jaune	17
1622	27508	775	rouge	47
1623	35676	775	jaune	52
1624	72448	776	jaune	35
1625	89154	776	jaune	36
1626	63068	776	jaune	65
1627	27618	776	jaune	79
1628	49007	777	jaune	3
1629	5425	777	rouge	28
1630	84003	777	jaune	58
1631	24324	777	jaune	68
1632	4065	777	jaune	70
1633	32695	777	jaune	89
1634	50749	778	jaune	10
1635	26474	778	jaune	28
1636	96174	778	jaune	44
1637	92146	778	jaune	54
1638	18894	778	jaune	60
1639	22492	779	jaune	18
1640	77687	779	jaune	19
1641	33665	779	jaune	46
1642	9117	779	jaune	47
1643	40120	779	jaune	55
1644	65534	779	jaune	64
1645	82458	780	jaune	3
1646	5583	780	jaune	14
1647	30568	780	jaune	48
1648	17884	780	jaune	51
1649	429	780	jaune	54
1650	45212	780	jaune	60
1651	42797	780	jaune	74
1652	44396	780	jaune	85
1653	50012	781	jaune	7
1654	85128	781	jaune	27
1655	19888	781	jaune	36
1656	55456	781	jaune	42
1657	37893	781	rouge	65
1658	48968	782	jaune	25
1659	23705	782	jaune	34
1660	40197	782	jaune	35
1661	99466	782	jaune	41
1662	69700	782	jaune	58
1663	8544	782	jaune	66
1664	18113	782	jaune	94
1665	75104	783	jaune	13
1666	88171	783	rouge	44
1667	95366	783	jaune	50
1668	10860	783	jaune	59
1669	24930	783	jaune	86
1670	59901	784	jaune	20
1671	16154	784	jaune	32
1672	57982	784	jaune	46
1673	96343	784	jaune	48
1674	80908	784	jaune	61
1675	55405	784	jaune	73
1676	20762	784	jaune	88
1677	23846	785	jaune	18
1678	12805	785	jaune	37
1679	36056	785	jaune	49
1680	91280	785	rouge	65
1681	38556	785	jaune	66
1682	49882	785	jaune	75
1683	50641	785	jaune	84
1684	384	785	jaune	93
1685	42038	786	jaune	5
1686	2842	786	rouge	21
1687	65802	786	rouge	28
1688	58649	786	rouge	45
1689	42227	786	jaune	70
1690	11915	787	jaune	21
1691	61666	787	jaune	32
1692	54298	787	jaune	42
1693	97008	787	jaune	69
1694	42311	787	jaune	72
1695	83566	788	jaune	13
1696	91718	788	jaune	29
1697	62722	788	jaune	31
1698	21864	788	jaune	39
1699	13354	788	jaune	83
1700	92775	789	jaune	11
1701	61550	789	jaune	29
1702	4469	789	jaune	79
1703	56430	789	jaune	85
1704	57309	790	jaune	45
1705	48772	790	jaune	47
1706	80410	790	jaune	53
1707	17148	790	jaune	92
1708	17420	791	jaune	22
1709	53448	791	jaune	41
1710	585	791	jaune	57
1711	50973	791	jaune	73
1712	98387	791	jaune	77
1713	18200	791	jaune	89
1714	51089	792	jaune	30
1715	40581	792	jaune	32
1716	82870	792	jaune	40
1717	76769	792	jaune	70
1718	33293	792	jaune	81
1719	640	792	jaune	85
1720	81297	792	jaune	89
1721	61850	792	jaune	93
1722	52458	793	jaune	17
1723	52481	793	jaune	18
1724	46873	793	jaune	24
1725	15578	793	jaune	29
1726	50749	793	jaune	47
1727	55170	793	jaune	47
1728	97927	793	jaune	56
1729	12680	793	jaune	60
1730	12856	793	jaune	76
1731	32695	793	jaune	91
1732	49265	794	jaune	52
1733	8154	794	jaune	75
1734	42797	795	jaune	30
1735	52480	795	jaune	45
1736	77687	795	jaune	48
1737	35595	795	jaune	54
1738	61216	796	jaune	76
1739	42808	796	jaune	83
1740	84022	796	jaune	87
1741	3457	797	jaune	22
1742	16154	797	jaune	37
1743	74131	797	jaune	46
1744	20969	797	jaune	55
1745	95366	797	jaune	67
1746	34386	797	jaune	91
1747	11191	798	jaune	22
1748	28497	798	jaune	26
1749	17445	798	rouge	27
1750	44763	798	jaune	65
1751	17581	798	jaune	69
1752	30651	798	jaune	87
1753	68375	798	jaune	88
1754	57631	798	jaune	91
1755	85128	799	rouge	17
1756	98071	799	jaune	33
1757	79645	799	jaune	35
1758	8415	799	jaune	37
1759	20335	799	rouge	41
1760	93241	799	jaune	43
1761	41962	799	jaune	57
1762	33312	800	jaune	28
1763	96131	800	jaune	42
1764	13377	800	jaune	48
1765	66229	800	jaune	57
1766	77063	800	jaune	90
1767	18164	801	jaune	31
1768	30878	801	rouge	35
1769	12805	802	jaune	5
1770	97784	802	jaune	7
1771	52437	802	jaune	32
1772	29967	802	jaune	81
1773	9728	802	jaune	91
1774	41724	803	rouge	32
1775	42144	803	jaune	38
1776	29621	803	rouge	61
1777	85818	803	jaune	70
1778	83566	803	rouge	81
1779	87604	804	jaune	40
1780	30363	804	jaune	44
1781	88041	805	jaune	27
1782	21683	805	jaune	30
1783	83711	805	jaune	35
1784	15314	805	jaune	75
1785	20886	805	jaune	77
1786	640	806	rouge	9
1787	18200	806	jaune	18
1788	89154	806	jaune	43
1789	56584	806	jaune	47
1790	60675	806	jaune	61
1791	7368	806	jaune	65
1792	76769	806	jaune	90
1793	6608	807	jaune	23
1794	76780	807	jaune	37
1795	94161	807	jaune	43
1796	59636	807	jaune	55
1797	56006	807	jaune	69
1798	7865	807	jaune	78
1799	26616	807	jaune	78
1800	22338	807	jaune	80
1801	10953	807	jaune	82
1802	25758	807	jaune	90
1803	93048	808	jaune	30
1804	43931	808	jaune	38
1805	64772	808	jaune	44
1806	57309	808	jaune	88
1807	35264	809	jaune	27
1808	30568	809	rouge	28
1809	20557	809	jaune	48
1810	45212	809	jaune	78
1811	64352	810	jaune	46
1812	44763	810	jaune	70
1813	86098	810	jaune	82
1814	60914	810	jaune	112
1815	89297	810	jaune	118
1816	89438	810	jaune	119
1817	71420	811	jaune	18
1818	49265	811	jaune	24
1819	86943	811	jaune	37
1820	92146	811	jaune	67
1821	72859	811	jaune	78
1822	50944	811	jaune	82
1823	69700	812	jaune	2
1824	46895	812	rouge	7
1825	17581	812	jaune	20
1826	80908	812	rouge	31
1827	92307	812	jaune	50
1828	21832	812	rouge	59
1829	57496	812	jaune	60
1830	96343	812	rouge	73
1831	51336	812	jaune	73
1832	68125	812	jaune	74
1833	45712	812	jaune	76
1834	62437	812	jaune	76
1835	63129	813	jaune	23
1836	99473	813	jaune	29
1837	44926	813	jaune	49
1838	37126	813	rouge	50
1839	14862	813	jaune	61
1840	18164	813	jaune	89
1841	42227	813	jaune	91
1842	97143	814	jaune	59
1843	9728	815	jaune	7
1844	50641	815	jaune	11
1845	20372	815	jaune	13
1846	25083	815	jaune	29
1847	77757	815	jaune	38
1848	98607	815	jaune	44
1849	38556	815	rouge	48
1850	96540	816	jaune	68
1851	51089	816	jaune	82
1852	55659	816	jaune	87
1853	56430	816	jaune	91
1854	36287	817	jaune	3
1855	60914	817	jaune	46
1856	77063	817	jaune	60
1857	33570	817	jaune	88
1858	24324	817	jaune	94
1859	38198	817	jaune	95
1860	43481	817	jaune	114
1861	16541	817	rouge	120
1862	18200	818	jaune	16
1863	98387	818	jaune	21
1864	69073	818	jaune	67
1865	71420	819	jaune	30
1866	92307	819	jaune	44
1867	99967	819	rouge	62
1868	61216	819	jaune	107
1869	37760	819	jaune	111
1870	91718	820	jaune	25
1871	98607	820	jaune	45
1872	62722	820	jaune	47
1873	23315	820	jaune	74
1874	42918	820	jaune	75
1875	48944	820	jaune	87
1876	56947	820	jaune	88
1877	8154	821	jaune	40
1878	4065	821	jaune	56
1879	22378	821	jaune	90
1880	37760	822	jaune	83
1881	48944	822	jaune	87
1882	35264	823	jaune	7
1883	55321	823	jaune	24
1884	80908	823	jaune	33
1885	16378	823	jaune	60
1886	43400	823	jaune	78
1887	42227	824	jaune	5
1888	23315	824	jaune	12
1889	58415	824	jaune	76
1890	56430	824	rouge	110
1891	18830	824	jaune	111
1892	23308	825	jaune	16
1893	65068	825	jaune	20
1894	24548	825	jaune	56
1895	47092	825	jaune	60
1896	96080	825	jaune	86
1897	8904	825	jaune	92
1898	471	826	jaune	45
1899	92164	826	jaune	91
1900	73084	827	jaune	23
1901	12357	827	jaune	94
1902	95194	828	jaune	12
1903	26286	829	jaune	53
1904	14085	829	jaune	87
1905	19145	829	jaune	90
1906	61084	830	jaune	25
1907	11819	832	jaune	80
1908	5784	832	jaune	86
1909	57621	832	jaune	89
1910	51492	833	jaune	57
1911	48787	834	jaune	34
1912	94354	834	jaune	93
1913	73084	835	jaune	16
1914	67377	835	jaune	36
1915	10986	835	jaune	55
1916	47092	835	jaune	84
1917	54473	835	jaune	85
1918	38422	836	jaune	35
1919	69273	836	jaune	52
1920	59010	836	jaune	77
1921	77759	837	jaune	8
1922	68309	837	jaune	21
1923	23665	837	jaune	39
1924	68729	837	jaune	78
1925	32154	838	jaune	60
1926	393	838	jaune	88
1927	59575	838	jaune	91
1928	46780	840	jaune	10
1929	67766	840	jaune	27
1930	84724	840	jaune	41
1931	72394	840	jaune	53
1932	31275	840	jaune	61
1933	22178	841	jaune	4
1934	24795	841	rouge	41
1935	24548	841	jaune	42
1936	10986	841	jaune	61
1937	46224	842	jaune	16
1938	8780	842	jaune	82
1939	80012	842	jaune	88
1940	94784	843	jaune	14
1941	82102	844	jaune	31
1942	83515	844	jaune	32
1943	96721	844	jaune	82
1944	67990	844	jaune	88
1945	20	845	jaune	89
1946	87492	845	jaune	90
1947	96825	846	jaune	15
1948	54127	846	jaune	74
1949	80373	847	jaune	42
1950	22757	847	jaune	76
1951	16994	848	jaune	25
1952	58561	848	jaune	56
1953	95180	848	jaune	72
1954	63421	849	jaune	51
1955	36571	851	jaune	59
1956	54442	851	jaune	69
1957	74483	851	jaune	83
1958	29694	851	jaune	85
1959	4506	852	jaune	63
1960	42226	852	jaune	85
1961	97621	853	jaune	14
1962	92403	854	rouge	14
1963	69030	854	jaune	26
1964	84724	854	jaune	28
1965	31275	854	jaune	45
1966	89236	854	jaune	49
1967	69030	855	jaune	28
1968	8780	856	jaune	7
1969	46780	856	jaune	59
1970	15303	856	jaune	63
1971	85916	857	jaune	18
1972	92279	857	jaune	27
1973	89297	857	jaune	57
1974	37930	857	jaune	70
1975	72916	858	jaune	12
1976	55659	858	jaune	19
1977	92649	858	jaune	59
1978	36662	858	rouge	65
1979	9884	858	jaune	68
1980	89878	858	jaune	93
1981	5210	859	jaune	56
1982	56859	860	jaune	41
1983	98826	860	jaune	77
1984	95616	861	jaune	26
1985	77238	861	jaune	39
1986	78640	861	jaune	47
1987	50944	861	jaune	60
1988	62157	861	jaune	61
1989	36179	861	jaune	74
1990	6159	862	jaune	35
1991	22008	862	rouge	59
1992	75452	862	jaune	93
1993	70560	862	jaune	95
1994	18094	863	jaune	19
1995	56448	863	jaune	26
1996	32588	863	rouge	54
1997	88851	863	jaune	83
1998	69641	863	jaune	89
1999	12818	864	jaune	12
2000	66908	864	jaune	24
2001	91832	864	jaune	46
2002	44926	864	rouge	56
2003	70545	864	jaune	58
2004	10713	864	jaune	92
2005	53668	865	jaune	44
2006	99934	865	jaune	49
2007	14988	865	jaune	63
2008	93209	866	jaune	72
2009	148	866	jaune	91
2010	21823	867	jaune	62
2011	22378	867	jaune	70
2012	10960	868	jaune	42
2013	37913	868	jaune	55
2014	57058	868	jaune	93
2015	48968	869	jaune	7
2016	75763	869	jaune	21
2017	70442	869	jaune	21
2018	86499	870	jaune	88
2019	41671	871	jaune	4
2020	96009	871	jaune	19
2021	15185	871	jaune	33
2022	49127	872	jaune	30
2023	9704	872	jaune	73
2024	46325	872	jaune	91
2025	59636	872	jaune	94
2026	38095	873	jaune	6
2027	92279	873	jaune	42
2028	38574	873	rouge	76
2029	32822	874	jaune	10
2030	40927	874	jaune	34
2031	56859	874	jaune	54
2032	77063	874	jaune	55
2033	64352	874	jaune	74
2034	11436	875	jaune	15
2035	34118	875	rouge	33
2036	10140	875	jaune	59
2037	58348	875	jaune	88
2038	62448	875	jaune	89
2039	73255	876	jaune	4
2040	9884	876	jaune	46
2041	85916	876	jaune	48
2042	21208	876	jaune	49
2043	4469	876	jaune	78
2044	11191	876	jaune	82
2045	27787	877	rouge	12
2046	95482	877	jaune	18
2047	33059	877	jaune	19
2048	13029	877	jaune	22
2049	18599	877	jaune	32
2050	47415	877	jaune	57
2051	68901	877	jaune	59
2052	43400	877	jaune	73
2053	68662	878	jaune	35
2054	36179	878	jaune	40
2055	10829	878	jaune	69
2056	91038	878	jaune	72
2057	65942	878	jaune	75
2058	50944	879	jaune	58
2059	23484	879	jaune	85
2060	20084	880	jaune	36
2061	14290	881	rouge	24
2062	56284	881	jaune	40
2063	93750	881	jaune	79
2064	50270	881	jaune	84
2065	66908	881	jaune	85
2066	68512	882	jaune	49
2067	48783	882	jaune	75
2068	212	882	jaune	86
2069	14988	882	jaune	87
2070	88680	883	jaune	42
2071	18210	883	jaune	45
2072	26852	883	jaune	47
2073	57948	883	jaune	84
2074	57948	883	rouge	84
2075	20963	884	jaune	14
2076	84524	884	jaune	28
2077	81126	884	jaune	87
2078	59702	885	jaune	31
2079	98071	885	jaune	75
2080	58388	885	rouge	85
2081	19801	885	jaune	86
2082	35746	886	jaune	32
2083	47801	886	jaune	38
2084	57041	886	jaune	47
2085	14428	886	jaune	70
2086	66477	887	jaune	2
2087	27813	887	jaune	18
2088	41671	887	jaune	22
2089	23300	887	jaune	25
2090	54713	887	rouge	31
2091	97143	887	jaune	48
2092	96009	887	jaune	60
2093	9596	887	jaune	60
2094	49014	887	jaune	61
2095	65631	887	jaune	92
2096	6476	888	jaune	8
2097	57482	888	jaune	38
2098	72795	889	rouge	25
2099	82555	889	jaune	71
2100	95196	890	jaune	68
2101	36515	890	jaune	77
2102	2461	890	jaune	86
2103	52378	891	jaune	30
2104	6108	891	jaune	76
2105	39249	892	jaune	31
2106	62448	892	jaune	37
2107	4333	892	jaune	42
2108	51785	892	jaune	68
2109	65942	893	jaune	40
2110	43764	893	jaune	48
2111	20008	893	jaune	79
2112	21784	893	jaune	81
2113	70560	894	jaune	12
2114	7475	894	jaune	62
2115	77742	894	rouge	76
2116	23484	894	jaune	83
2117	91976	894	jaune	90
2118	32588	895	jaune	18
2119	69089	895	jaune	49
2120	14862	895	jaune	50
2121	71962	895	jaune	59
2122	83566	895	jaune	67
2123	1945	896	jaune	40
2124	28154	896	jaune	43
2125	21823	897	jaune	10
2126	34530	897	jaune	41
2127	81126	897	jaune	56
2128	37913	898	jaune	16
2129	88863	898	jaune	31
2130	14764	898	jaune	40
2131	55404	898	jaune	50
2132	92874	898	jaune	67
2133	47246	898	jaune	76
2134	83904	898	jaune	82
2135	1045	898	jaune	83
2136	33312	899	jaune	17
2137	93209	899	jaune	25
2138	68125	899	jaune	65
2139	21832	899	jaune	70
2140	48783	899	jaune	81
2141	61292	900	jaune	12
2142	26303	900	jaune	26
2143	83625	900	jaune	29
2144	46718	900	jaune	48
2145	38862	900	jaune	66
2146	98528	902	jaune	15
2147	8069	902	jaune	25
2148	98607	902	jaune	25
2149	21434	902	jaune	31
2150	81972	902	jaune	40
2151	58840	902	jaune	43
2152	92000	902	jaune	45
2153	49014	903	jaune	15
2154	23300	903	jaune	19
2155	8305	903	rouge	21
2156	45221	904	jaune	4
2157	77553	904	jaune	34
2158	54804	904	jaune	58
2159	53363	904	jaune	64
2160	15185	904	jaune	89
2161	47942	905	jaune	38
2162	39884	905	jaune	69
2163	16580	905	jaune	83
2164	64198	906	jaune	7
2165	77238	906	jaune	18
2166	93750	906	jaune	61
2167	12548	906	jaune	68
2168	1945	906	jaune	92
2169	43481	907	jaune	47
2170	43764	907	jaune	81
2171	44763	908	jaune	28
2172	23705	909	jaune	31
2173	18379	909	jaune	40
2174	40368	909	jaune	72
2175	57606	909	jaune	84
2176	36850	909	jaune	93
2177	58388	910	jaune	30
2178	41001	910	jaune	47
2179	98593	910	jaune	68
2180	86499	910	jaune	72
2181	39840	910	jaune	80
2182	3497	911	jaune	58
2183	26303	911	jaune	72
2184	33175	911	jaune	93
2185	61292	911	jaune	113
2186	78654	911	jaune	118
2187	73924	912	jaune	74
2188	21434	912	jaune	80
2189	55321	912	rouge	89
2190	28832	913	jaune	14
2191	86163	913	jaune	37
2192	20084	913	jaune	47
2193	53668	913	jaune	64
2194	58840	913	rouge	73
2195	96131	913	jaune	76
2196	95196	914	jaune	20
2197	80668	914	jaune	48
2198	25083	914	jaune	54
2199	53254	914	jaune	59
2200	24586	914	jaune	77
2201	29967	914	jaune	93
2202	30486	914	rouge	121
2203	49114	915	jaune	11
2204	28154	915	jaune	35
2205	77063	915	jaune	80
2206	64348	916	jaune	57
2207	87859	916	jaune	59
2208	21823	916	jaune	59
2209	28010	916	jaune	63
2210	53028	916	jaune	71
2211	33360	916	jaune	88
2212	41944	917	jaune	21
2213	74058	917	jaune	29
2214	51336	917	jaune	29
2215	46895	917	jaune	78
2216	69700	917	jaune	95
2217	4201	919	jaune	5
2218	10713	919	jaune	7
2219	53254	919	jaune	61
2220	43481	919	jaune	92
2221	99934	920	jaune	15
2222	51089	920	jaune	16
2223	69700	920	jaune	22
2224	89177	920	jaune	23
2225	53668	920	jaune	28
2226	21832	920	jaune	54
2227	28832	920	rouge	57
2228	47753	920	jaune	67
2229	23705	920	jaune	84
2230	20084	920	jaune	111
2231	40197	920	jaune	117
2232	56330	920	jaune	118
2233	29415	920	jaune	121
2234	47092	922	jaune	81
2235	67377	922	jaune	90
2236	19118	923	jaune	46
2237	46683	923	jaune	67
2238	57283	923	jaune	77
2239	40448	924	jaune	87
2240	77877	924	jaune	88
2241	94354	925	jaune	29
2242	74073	927	jaune	63
2243	38110	927	jaune	92
2244	25958	929	jaune	37
2245	28528	929	jaune	52
2246	23374	930	jaune	51
2247	34124	930	jaune	74
2248	94354	933	jaune	60
2249	89236	934	jaune	84
2250	37720	935	jaune	41
2251	325	935	jaune	46
2252	83079	935	jaune	72
2253	21565	935	jaune	79
2254	25746	936	jaune	19
2255	82057	938	jaune	33
2256	92275	938	jaune	91
2257	21975	939	jaune	59
2258	37178	940	jaune	17
2259	81978	940	jaune	40
2260	75036	940	jaune	41
2261	32017	940	jaune	59
2262	44882	940	rouge	65
2263	54473	940	jaune	82
2264	77401	941	jaune	47
2265	47947	941	jaune	68
2266	820	941	jaune	92
2267	94069	942	jaune	9
2268	9953	942	jaune	60
2269	51448	942	jaune	74
2270	31275	942	jaune	77
2271	36010	942	jaune	92
2272	72716	944	jaune	14
2273	52228	944	jaune	60
2274	10986	945	jaune	5
2275	84864	945	jaune	77
2276	90789	945	jaune	87
2277	41187	945	jaune	93
2278	55574	946	jaune	55
2279	99210	946	jaune	72
2280	72113	946	jaune	87
2281	59869	946	jaune	106
2282	90878	946	jaune	115
2283	77133	947	jaune	23
2284	95194	947	jaune	67
2285	47947	947	jaune	80
2286	52228	947	jaune	81
2287	62104	948	jaune	29
2288	84724	948	jaune	44
2289	7458	948	jaune	45
2290	76699	948	rouge	65
2291	80833	948	jaune	67
2292	9273	948	jaune	90
2293	26798	948	jaune	112
2294	92403	948	jaune	113
2295	82497	948	jaune	117
2296	3998	949	jaune	90
2297	98700	950	jaune	70
2298	29677	951	rouge	68
2299	87008	953	jaune	27
2300	8916	953	jaune	65
2301	56297	953	jaune	69
2302	43410	953	jaune	88
2303	21208	954	jaune	57
2304	89372	954	jaune	77
2305	93667	955	jaune	25
2306	70280	955	jaune	41
2307	61793	955	jaune	65
2308	99934	955	jaune	66
2309	44926	956	jaune	44
2310	37275	956	jaune	58
2311	36196	956	jaune	67
2312	22391	956	jaune	86
2313	66228	957	jaune	26
2314	11436	957	jaune	52
2315	75292	957	jaune	55
2316	89878	958	jaune	50
2317	78735	958	jaune	56
2318	74058	958	jaune	81
2319	41944	958	rouge	94
2320	21553	959	jaune	92
2321	89321	960	jaune	23
2322	55416	960	jaune	54
2323	48968	960	jaune	58
2324	27263	960	jaune	64
2325	43280	961	jaune	53
2326	25758	961	jaune	84
2327	72916	962	jaune	7
2328	17509	962	jaune	28
2329	15185	962	rouge	28
2330	67867	962	jaune	47
2331	93922	962	jaune	53
2332	29674	962	jaune	83
2333	18222	963	jaune	25
2334	68768	963	jaune	63
2335	17971	964	jaune	11
2336	81972	964	rouge	37
2337	20969	965	jaune	75
2338	96497	966	jaune	30
2339	50641	966	jaune	92
2340	64049	967	jaune	24
2341	96340	967	jaune	34
2342	86499	968	jaune	45
2343	1835	968	jaune	59
2344	22756	968	jaune	62
2345	32798	968	jaune	79
2346	77335	969	jaune	13
2347	48433	969	jaune	30
2348	27894	969	jaune	49
2349	47440	969	jaune	90
2350	44926	970	jaune	43
2351	99934	970	jaune	47
2352	41001	971	jaune	26
2353	73924	971	jaune	41
2354	9990	971	jaune	61
2355	99407	972	rouge	40
2356	15665	972	jaune	89
2357	48968	973	jaune	55
2358	19801	973	jaune	90
2359	78440	974	jaune	9
2360	62157	974	jaune	68
2361	91793	975	jaune	12
2362	52378	975	rouge	27
2363	58348	975	jaune	55
2364	5210	975	jaune	89
2365	16785	976	jaune	69
2366	71361	976	jaune	71
2367	67867	977	jaune	88
2368	82662	978	jaune	7
2369	67290	978	jaune	48
2370	49265	978	jaune	57
2371	75912	978	jaune	73
2372	55935	978	jaune	80
2373	59901	979	jaune	53
2374	111	979	jaune	73
2375	50641	980	jaune	94
2376	34727	981	jaune	6
2377	1164	981	jaune	81
2378	30808	982	jaune	38
2379	53048	982	jaune	54
2380	70547	982	jaune	73
2381	64718	983	jaune	54
2382	21116	983	jaune	67
2383	29447	983	jaune	69
2384	10072	984	jaune	75
2385	89177	985	jaune	62
2386	77068	985	jaune	88
2387	37275	985	jaune	92
2388	94202	986	jaune	25
2389	39861	986	jaune	64
2390	48455	987	jaune	11
2391	72737	987	jaune	76
2392	48783	987	jaune	80
2393	65979	988	jaune	9
2394	44763	988	jaune	39
2395	22756	988	jaune	66
2396	44463	988	rouge	89
2397	48443	989	jaune	53
2398	22075	989	jaune	57
2399	4808	989	jaune	60
2400	16785	990	jaune	22
2401	80668	990	jaune	46
2402	37848	990	rouge	59
2403	67615	990	jaune	77
2404	10014	990	jaune	91
2405	85824	991	jaune	16
2406	66638	991	jaune	63
2407	99466	992	jaune	37
2408	31976	992	jaune	62
2409	54100	992	jaune	70
2410	74144	993	jaune	78
2411	53957	993	jaune	88
2412	98806	994	jaune	49
2413	79048	994	jaune	51
2414	73160	995	jaune	66
2415	49265	996	rouge	50
2416	52676	996	jaune	83
2417	5368	997	jaune	39
2418	24388	997	jaune	55
2419	31765	997	jaune	78
2420	89743	997	jaune	94
2421	54036	998	jaune	11
2422	20244	998	jaune	37
2423	45750	998	jaune	62
2424	9059	999	jaune	39
2425	63644	999	jaune	57
2426	21554	999	jaune	59
2427	31598	999	jaune	87
2428	98016	999	jaune	92
2429	55453	1000	jaune	35
2430	3735	1000	rouge	45
2431	12533	1000	jaune	50
2432	9990	1001	jaune	17
2433	94202	1001	jaune	40
2434	86524	1001	jaune	55
2435	43410	1001	jaune	60
2436	37372	1001	jaune	93
2437	89582	1001	jaune	102
2438	9441	1001	jaune	106
2439	65659	1002	jaune	55
2440	89878	1002	jaune	77
2441	95402	1002	jaune	78
2442	1835	1003	jaune	69
2443	44763	1003	jaune	92
2444	40312	1003	jaune	93
2445	30845	1004	jaune	36
2446	97912	1004	rouge	42
2447	24978	1004	jaune	48
2448	85499	1004	jaune	57
2449	99590	1004	jaune	70
2450	23816	1004	jaune	72
2451	81392	1004	jaune	90
2452	4964	1005	jaune	54
2453	19453	1006	jaune	42
2454	18599	1006	jaune	107
2455	77224	1007	jaune	36
2456	77553	1007	jaune	73
2457	18222	1007	jaune	90
2458	42113	1007	jaune	120
2459	61051	1007	jaune	124
2460	31173	1008	jaune	18
2461	95269	1008	jaune	42
2462	13029	1009	jaune	54
2463	43400	1009	jaune	80
2464	32798	1010	jaune	64
2465	89392	1010	jaune	67
2466	92771	1010	jaune	71
2467	11275	1010	jaune	78
2468	72011	1011	jaune	53
2469	70547	1011	jaune	69
2470	38647	1011	jaune	75
2471	81779	1012	jaune	37
2472	52458	1012	jaune	52
2473	69329	1012	jaune	64
2474	4808	1012	jaune	81
2475	65320	1012	jaune	107
2476	64344	1012	jaune	111
2477	93619	1013	jaune	68
2478	69329	1014	jaune	45
2479	39810	1014	jaune	49
2480	64344	1014	jaune	105
2481	32798	1015	jaune	2
2482	23705	1015	jaune	9
2483	93667	1015	jaune	36
2484	41758	1015	jaune	54
2485	37239	1015	jaune	68
2486	43400	1016	jaune	29
2487	54036	1016	jaune	34
2488	77063	1016	jaune	64
2489	36870	1016	jaune	65
2490	36065	1017	jaune	22
2491	70845	1018	jaune	32
2492	336	1018	jaune	64
2493	26203	1019	jaune	51
2494	8487	1019	jaune	75
2495	97929	1020	jaune	36
2496	54977	1020	jaune	40
2497	75197	1020	jaune	58
2498	39616	1020	jaune	66
2499	52652	1020	jaune	70
2500	6222	1020	jaune	86
2501	95451	1022	jaune	38
2502	62444	1022	jaune	43
2503	86830	1022	jaune	47
2504	16218	1022	rouge	66
2505	24375	1022	jaune	70
2506	81449	1023	jaune	56
2507	9273	1023	jaune	64
2508	61487	1024	jaune	22
2509	47686	1024	jaune	28
2510	7698	1024	jaune	93
2511	73084	1025	jaune	66
2512	70737	1026	jaune	44
2513	18004	1027	jaune	18
2514	92991	1027	jaune	26
2515	85632	1027	jaune	34
2516	24999	1027	jaune	55
2517	35864	1028	jaune	52
2518	96080	1030	jaune	59
2519	97105	1031	jaune	31
2520	61084	1031	jaune	52
2521	24335	1031	jaune	71
2522	95918	1032	jaune	94
2523	86883	1033	jaune	72
2524	62439	1034	jaune	42
2525	9202	1034	jaune	60
2526	83450	1035	jaune	43
2527	97803	1037	jaune	69
2528	68128	1037	jaune	79
2529	47865	1038	jaune	23
2530	11773	1038	jaune	92
2531	40448	1039	jaune	64
2532	34666	1039	jaune	92
2533	58271	1040	jaune	69
2534	97215	1040	jaune	81
2535	73479	1040	jaune	86
2536	23964	1041	jaune	82
2537	52652	1042	jaune	25
2538	48031	1042	jaune	52
2539	97958	1043	jaune	75
2540	393	1043	jaune	83
2541	26515	1043	jaune	86
2542	82898	1043	jaune	86
2543	31118	1044	jaune	72
2544	13594	1044	jaune	73
2545	1302	1045	jaune	19
2546	69986	1045	jaune	35
2547	36793	1045	jaune	68
2548	97288	1045	jaune	82
2549	18928	1045	jaune	92
2550	86882	1046	jaune	17
2551	28880	1046	jaune	39
2552	72265	1046	jaune	52
2553	17938	1047	rouge	38
2554	21975	1047	jaune	43
2555	9202	1047	jaune	60
2556	22604	1047	jaune	68
2557	76437	1049	jaune	36
2558	41243	1049	jaune	37
2559	22178	1049	jaune	65
2560	97803	1049	jaune	85
2561	91979	1050	jaune	62
2562	32979	1050	jaune	87
2563	65568	1051	jaune	56
2564	73479	1051	jaune	69
2565	96080	1053	jaune	28
2566	2921	1053	jaune	35
2567	96721	1053	jaune	68
2568	36793	1054	jaune	93
2569	6224	1055	jaune	14
2570	7458	1055	jaune	81
2571	70687	1056	jaune	33
2572	8612	1056	jaune	80
2573	97215	1056	jaune	85
2574	97813	1057	jaune	13
2575	84754	1057	jaune	46
2576	60142	1057	jaune	74
2577	81449	1059	jaune	17
2578	9273	1059	jaune	41
2579	9774	1059	rouge	47
2580	28701	1059	jaune	65
2581	66148	1060	jaune	50
2582	30564	1061	jaune	37
2583	89379	1061	jaune	55
2584	75036	1061	jaune	57
2585	37178	1061	jaune	68
2586	84273	1061	jaune	68
2587	17418	1061	jaune	91
2588	66124	1062	jaune	50
2589	55574	1063	jaune	27
2590	76594	1064	jaune	63
2591	68495	1064	jaune	93
2592	32680	1065	jaune	34
2593	64276	1065	jaune	38
2594	65433	1065	jaune	59
2595	67377	1065	jaune	67
2596	35919	1066	jaune	31
2597	20246	1066	jaune	90
2598	73084	1067	jaune	77
2599	90789	1067	jaune	83
2600	69145	1067	jaune	92
2601	72113	1068	jaune	82
2602	26643	1068	jaune	85
2603	22778	1069	jaune	88
2604	66636	1069	jaune	93
2605	50801	1070	jaune	94
2606	81689	1070	jaune	96
2607	111	1071	jaune	10
2608	62364	1071	jaune	34
2609	98775	1071	jaune	47
2610	53957	1071	jaune	92
2611	28010	1072	jaune	17
2612	39584	1072	jaune	28
2613	35837	1073	jaune	13
2614	87852	1073	jaune	57
2615	54461	1073	jaune	76
2616	51118	1073	jaune	87
2617	82532	1075	jaune	38
2618	57615	1075	jaune	86
2619	8442	1075	jaune	93
2620	65979	1076	jaune	30
2621	15870	1076	jaune	70
2622	79215	1076	jaune	89
2623	71100	1077	jaune	22
2624	33347	1077	jaune	56
2625	95482	1077	jaune	59
2626	40618	1077	jaune	98
2627	21208	1078	jaune	40
2628	28154	1078	jaune	83
2629	81447	1078	jaune	84
2630	42911	1078	jaune	90
2631	9988	1079	jaune	31
2632	2305	1079	jaune	47
2633	25131	1079	jaune	65
2634	54713	1079	jaune	68
2635	15736	1080	jaune	13
2636	58692	1080	jaune	55
2637	78477	1080	jaune	61
2638	22930	1081	jaune	14
2639	44505	1081	jaune	18
2640	10561	1081	jaune	47
2641	6696	1081	jaune	49
2642	72819	1081	jaune	51
2643	24760	1081	jaune	57
2644	64049	1081	jaune	59
2645	48955	1081	jaune	88
2646	74071	1082	jaune	33
2647	66228	1083	rouge	3
2648	17988	1083	jaune	64
2649	89392	1083	jaune	86
2650	53272	1083	jaune	94
2651	45449	1084	jaune	12
2652	91655	1084	jaune	49
2653	40621	1084	jaune	72
2654	82223	1085	jaune	57
2655	18383	1085	jaune	84
2656	53270	1086	jaune	40
2657	72710	1086	jaune	92
2658	24531	1088	jaune	79
2659	60139	1088	jaune	92
2660	8442	1089	jaune	37
2661	18907	1089	jaune	84
2662	4964	1090	jaune	16
2663	29117	1090	jaune	23
2664	59720	1090	jaune	81
2665	17509	1090	jaune	86
2666	44463	1091	jaune	39
2667	32508	1091	jaune	51
2668	25745	1091	jaune	58
2669	65425	1091	jaune	67
2670	49114	1091	jaune	85
2671	73712	1091	jaune	87
2672	8916	1091	jaune	94
2673	37171	1092	jaune	81
2674	87008	1092	jaune	81
2675	65320	1092	jaune	84
2676	1347	1093	jaune	44
2677	27744	1094	jaune	34
2678	44932	1094	jaune	39
2679	66184	1094	jaune	47
2680	85696	1094	jaune	87
2681	39460	1094	jaune	91
2682	90867	1095	jaune	14
2683	7259	1096	jaune	58
2684	64718	1096	jaune	63
2685	2947	1096	jaune	72
2686	64292	1096	jaune	80
2687	20019	1097	jaune	52
2688	4224	1097	rouge	71
2689	74946	1097	jaune	97
2690	6696	1098	jaune	10
2691	84745	1098	jaune	24
2692	91455	1098	jaune	44
2693	72819	1098	jaune	72
2694	23774	1099	jaune	59
2695	89984	1099	jaune	68
2696	55298	1099	jaune	90
2697	51960	1099	jaune	91
2698	91793	1099	jaune	94
2699	10172	1100	jaune	61
2700	57157	1100	jaune	85
2701	83293	1101	jaune	50
2702	44093	1101	jaune	86
2703	20571	1102	jaune	9
2704	64597	1102	rouge	27
2705	58791	1102	jaune	59
2706	62364	1103	jaune	21
2707	37696	1103	jaune	29
2708	99089	1103	jaune	31
2709	46553	1103	jaune	31
2710	15566	1103	jaune	88
2711	45288	1103	jaune	93
2712	67578	1104	jaune	33
2713	75785	1104	jaune	52
2714	9113	1104	jaune	54
2715	95670	1104	jaune	64
2716	70442	1104	jaune	83
2717	46272	1104	jaune	98
2718	37275	1105	jaune	10
2719	61528	1105	jaune	45
2720	10167	1105	jaune	60
2721	45548	1105	jaune	66
2722	88592	1105	jaune	79
2723	36196	1105	jaune	88
2724	61976	1106	jaune	48
2725	14891	1107	jaune	14
2726	7013	1107	jaune	59
2727	70085	1107	jaune	64
2728	65146	1107	jaune	83
2729	27331	1107	jaune	84
2730	65978	1108	jaune	32
2731	77063	1108	jaune	49
2732	66433	1108	jaune	64
2733	1164	1108	jaune	91
2734	14758	1108	jaune	94
2735	64292	1109	jaune	9
2736	93920	1109	jaune	23
2737	34018	1109	jaune	48
2738	77335	1109	jaune	65
2739	80088	1110	jaune	1
2740	74946	1110	jaune	26
2741	21208	1110	jaune	61
2742	10063	1110	jaune	86
2743	29833	1110	jaune	88
2744	45505	1111	jaune	33
2745	66184	1111	jaune	48
2746	85696	1111	jaune	70
2747	26483	1112	jaune	11
2748	70812	1112	jaune	29
2749	9988	1112	jaune	37
2750	83560	1112	jaune	75
2751	25131	1112	jaune	83
2752	37984	1112	jaune	89
2753	76596	1113	jaune	66
2754	7796	1114	jaune	45
2755	23774	1114	jaune	51
2756	47906	1115	jaune	19
2757	73834	1115	jaune	33
2758	90867	1116	jaune	44
2759	75361	1116	jaune	71
2760	67176	1116	jaune	78
2761	32575	1116	jaune	80
2762	9569	1116	jaune	93
2763	3144	1116	jaune	96
2764	18222	1117	jaune	11
2765	35173	1117	jaune	19
2766	77063	1117	jaune	43
2767	66433	1117	jaune	50
2768	4964	1117	jaune	72
2769	60652	1117	jaune	73
2770	89750	1117	jaune	93
2771	49114	1117	jaune	93
2772	70442	1118	jaune	93
2773	64348	1119	jaune	40
2774	82792	1119	jaune	54
2775	5922	1119	jaune	71
2776	61976	1120	jaune	115
2777	26546	1121	jaune	38
2778	65498	1121	jaune	43
2779	42911	1121	jaune	55
2780	2305	1121	jaune	59
2781	1730	1121	jaune	77
2782	40312	1121	jaune	92
2783	99817	1122	jaune	40
2784	29833	1123	jaune	31
2785	54713	1123	jaune	61
2786	77224	1123	jaune	68
2787	95507	1123	rouge	94
2788	17988	1124	jaune	41
2789	1505	1124	jaune	52
2790	66228	1124	jaune	54
2791	8169	1124	jaune	56
2792	74655	1124	jaune	63
2793	12476	1124	jaune	64
2794	63620	1124	jaune	69
2795	83216	1124	jaune	118
2796	84424	1125	jaune	33
2797	58791	1125	jaune	38
2798	14180	1125	jaune	69
2799	64077	1125	jaune	69
2800	70547	1126	jaune	47
2801	22930	1126	jaune	71
2802	41758	1126	jaune	85
2803	97493	1126	jaune	90
2804	89934	1127	jaune	87
2805	2465	1127	jaune	87
2806	74946	1127	jaune	94
2807	56297	1128	jaune	35
2808	86004	1128	jaune	38
2809	91294	1128	jaune	101
2810	20571	1128	jaune	109
2811	89420	1128	jaune	114
2812	72011	1129	jaune	63
2813	70547	1129	jaune	71
2814	98287	1129	jaune	87
2815	64077	1129	jaune	93
2816	64049	1129	jaune	94
2817	25745	1130	jaune	48
2818	74071	1130	jaune	54
2819	44463	1130	jaune	96
2820	92628	1131	jaune	52
2821	2465	1131	jaune	76
2822	53048	1131	jaune	93
2823	98287	1132	jaune	27
2824	84424	1132	jaune	41
2825	65425	1132	jaune	92
2826	40014	1134	jaune	12
2827	44771	1134	jaune	44
2828	97958	1134	jaune	50
2829	26515	1134	jaune	71
2830	70499	1134	jaune	82
2831	11968	1135	rouge	59
2832	13569	1135	jaune	68
2833	27801	1135	jaune	77
2834	84365	1135	jaune	94
2835	67645	1136	jaune	13
2836	86061	1136	jaune	46
2837	55953	1137	jaune	21
2838	49416	1137	jaune	63
2839	34581	1137	jaune	70
2840	83079	1137	jaune	76
2841	81939	1138	jaune	17
2842	19610	1138	jaune	58
2843	96976	1138	jaune	82
2844	86688	1139	jaune	43
2845	25596	1139	jaune	47
2846	54839	1140	jaune	38
2847	42768	1140	jaune	46
2848	26643	1140	jaune	85
2849	96889	1141	jaune	37
2850	18928	1141	jaune	74
2851	76573	1143	jaune	67
2852	18316	1143	jaune	78
2853	39388	1143	jaune	96
2854	69603	1144	jaune	72
2855	8264	1145	jaune	49
2856	19149	1145	jaune	61
2857	73479	1145	jaune	71
2858	59795	1146	jaune	63
2859	70239	1147	jaune	56
2860	56682	1147	jaune	71
2861	19610	1148	jaune	14
2862	91993	1148	jaune	85
2863	13960	1148	jaune	87
2864	45038	1149	jaune	83
2865	75658	1150	jaune	19
2866	4543	1150	jaune	36
2867	66845	1151	jaune	12
2868	52873	1151	jaune	59
2869	97512	1152	jaune	39
2870	76594	1152	jaune	47
2871	7642	1152	jaune	69
2872	22573	1153	jaune	14
2873	83450	1153	jaune	37
2874	1302	1153	jaune	68
2875	69603	1155	jaune	46
2876	5007	1155	jaune	95
2877	46428	1156	jaune	23
2878	55571	1156	jaune	76
2879	27240	1156	jaune	80
2880	98384	1156	jaune	88
2881	36548	1156	jaune	94
2882	45842	1157	jaune	63
2883	11369	1158	jaune	53
2884	83353	1158	jaune	54
2885	11968	1158	jaune	58
2886	16808	1158	jaune	66
2887	9501	1159	rouge	28
2888	44380	1159	jaune	46
2889	28304	1159	jaune	77
2890	19149	1159	jaune	99
2891	35864	1160	jaune	4
2892	56762	1160	jaune	85
2893	84606	1161	jaune	13
2894	94445	1161	jaune	15
2895	78371	1161	jaune	94
2896	81939	1162	jaune	71
2897	58730	1162	jaune	76
2898	23167	1164	jaune	75
2899	39315	1164	jaune	85
2900	16255	1164	jaune	86
2901	76817	1164	jaune	93
2902	54971	1165	jaune	68
2903	82188	1165	jaune	69
2904	53833	1166	jaune	23
2905	60142	1166	jaune	38
2906	71404	1166	jaune	80
2907	52476	1166	jaune	90
2908	72568	1167	jaune	59
2909	27729	1167	jaune	87
2910	23511	1168	jaune	59
2911	87745	1168	jaune	85
2912	62439	1169	jaune	26
2913	80216	1169	jaune	32
2914	25113	1169	jaune	57
2915	67645	1169	jaune	61
2916	30731	1169	jaune	82
2917	29295	1170	jaune	53
2918	67898	1170	jaune	96
2919	27559	1170	rouge	104
2920	22963	1170	jaune	107
2921	30264	1171	jaune	4
2922	82188	1171	jaune	100
2923	32017	1172	jaune	36
2924	60585	1172	jaune	47
2925	19610	1172	jaune	70
2926	42763	1172	jaune	82
2927	78371	1172	jaune	101
2928	9273	1173	jaune	37
2929	79226	1173	jaune	85
2930	99138	1174	jaune	45
2931	90086	1174	jaune	68
2932	60142	1174	jaune	85
2933	90878	1176	jaune	89
2934	85744	1177	jaune	88
2935	75169	1178	jaune	4
2936	81978	1178	jaune	94
2937	2903	1179	jaune	41
2938	31008	1179	jaune	66
2939	34581	1179	jaune	73
2940	26735	1179	jaune	79
2941	99138	1180	jaune	56
2942	42847	1181	rouge	40
2943	46428	1181	jaune	46
2944	64276	1181	jaune	82
2945	62542	1181	jaune	95
2946	12051	1182	jaune	85
2947	89508	1182	jaune	94
2948	70845	1182	jaune	116
2949	27779	1183	jaune	85
2950	76594	1183	jaune	94
2951	12051	1184	jaune	10
2952	97292	1184	jaune	42
2953	13594	1184	jaune	60
2954	70879	1185	jaune	15
2955	1930	1185	jaune	22
2956	82216	1185	jaune	29
2957	95754	1185	jaune	36
2958	56839	1185	jaune	56
2959	47319	1185	jaune	78
2960	98775	1186	jaune	25
2961	29864	1186	jaune	48
2962	73572	1187	jaune	56
2963	96697	1187	jaune	94
2964	40621	1187	jaune	96
2965	89452	1188	jaune	11
2966	68952	1188	jaune	13
2967	63927	1188	jaune	40
2968	74888	1188	jaune	47
2969	26367	1188	jaune	51
2970	86410	1188	jaune	100
2971	20216	1189	jaune	67
2972	87284	1189	jaune	75
2973	70583	1189	jaune	79
2974	8125	1189	jaune	82
2975	76864	1189	jaune	88
2976	85438	1189	jaune	92
2977	82877	1190	jaune	24
2978	26593	1190	jaune	78
2979	21865	1190	jaune	86
2980	24062	1191	jaune	29
2981	21208	1191	jaune	56
2982	23437	1191	jaune	76
2983	91029	1192	jaune	55
2984	34822	1192	jaune	80
2985	95847	1192	jaune	95
2986	71023	1193	jaune	78
2987	71100	1195	jaune	68
2988	70812	1195	jaune	97
2989	6338	1196	jaune	9
2990	22930	1196	jaune	54
2991	21652	1196	jaune	56
2992	46358	1196	jaune	81
2993	12635	1196	jaune	83
2994	47677	1197	jaune	36
2995	19193	1197	jaune	64
2996	23925	1197	jaune	83
2997	74058	1198	jaune	57
2998	87169	1198	jaune	88
2999	23821	1199	jaune	46
3000	1945	1199	jaune	49
3001	36105	1199	jaune	57
3002	98929	1199	jaune	91
3003	53967	1199	jaune	91
3004	39584	1199	jaune	95
3005	98435	1200	jaune	7
3006	24610	1200	jaune	49
3007	78056	1200	jaune	64
3008	38105	1201	jaune	48
3009	46457	1201	rouge	86
3010	47137	1201	jaune	95
3011	98775	1201	jaune	95
3012	1077	1202	jaune	20
3013	33622	1202	jaune	30
3014	33804	1202	jaune	47
3015	54506	1202	jaune	52
3016	61416	1202	jaune	87
3017	63532	1202	jaune	91
3018	56839	1203	jaune	57
3019	29063	1205	jaune	26
3020	64924	1205	jaune	64
3021	90867	1205	jaune	93
3022	44780	1206	jaune	15
3023	17099	1206	jaune	16
3024	12381	1206	jaune	19
3025	20216	1206	jaune	20
3026	12335	1206	jaune	49
3027	18923	1207	jaune	20
3028	29053	1207	jaune	23
3029	78484	1207	jaune	43
3030	38529	1208	jaune	22
3031	91431	1208	jaune	43
3032	64299	1208	jaune	50
3033	42911	1208	jaune	66
3034	73491	1208	jaune	89
3035	2556	1209	jaune	41
3036	45981	1209	jaune	44
3037	11767	1209	jaune	61
3038	71100	1209	jaune	70
3039	35225	1209	jaune	84
3040	53282	1209	jaune	93
3041	21652	1210	jaune	29
3042	5265	1210	jaune	95
3043	96259	1211	jaune	52
3044	56297	1211	jaune	56
3045	29491	1211	jaune	85
3046	31806	1211	jaune	85
3047	11933	1212	jaune	37
3048	28010	1212	jaune	44
3049	79409	1212	jaune	58
3050	30316	1212	jaune	60
3051	93209	1213	jaune	24
3052	51549	1213	jaune	30
3053	62033	1213	jaune	49
3054	57535	1213	jaune	93
3055	82956	1214	jaune	21
3056	64292	1214	jaune	27
3057	12913	1214	jaune	73
3058	7259	1214	jaune	77
3059	25593	1215	jaune	50
3060	74941	1215	jaune	52
3061	58791	1216	jaune	6
3062	22983	1216	jaune	38
3063	90796	1216	jaune	44
3064	17931	1216	jaune	77
3065	10712	1216	jaune	89
3066	40621	1217	jaune	66
3067	64438	1218	jaune	52
3068	14151	1219	jaune	43
3069	15905	1219	jaune	77
3070	74612	1219	jaune	83
3071	62858	1219	jaune	96
3072	74707	1220	jaune	29
3073	86951	1220	jaune	61
3074	51118	1221	jaune	4
3075	59727	1221	jaune	57
3076	76468	1221	jaune	75
3077	27079	1222	jaune	28
3078	73712	1223	jaune	49
3079	45449	1223	jaune	78
3080	26546	1224	jaune	16
3081	37308	1224	jaune	28
3082	45413	1224	jaune	34
3083	93173	1224	jaune	52
3084	20388	1224	jaune	81
3085	12335	1224	jaune	91
3086	84563	1224	jaune	97
3087	35706	1225	jaune	7
3088	27541	1225	jaune	26
3089	55821	1225	jaune	47
3090	89710	1225	jaune	84
3091	73834	1226	jaune	67
3092	97912	1227	jaune	77
3093	35225	1228	jaune	39
3094	77382	1228	jaune	44
3095	89321	1228	jaune	45
3096	18885	1229	jaune	20
3097	30486	1229	jaune	60
3098	33325	1229	jaune	86
3099	20051	1229	jaune	87
3100	36105	1229	jaune	99
3101	65659	1229	jaune	100
3102	59138	1229	jaune	100
3103	87514	1230	jaune	36
3104	58692	1230	jaune	92
3105	55367	1231	jaune	6
3106	55590	1231	jaune	7
3107	29115	1231	jaune	28
3108	47677	1231	jaune	32
3109	53452	1231	rouge	81
3110	74688	1231	jaune	85
3111	38927	1232	jaune	15
3112	85823	1232	jaune	34
3113	27744	1232	jaune	47
3114	98435	1232	jaune	56
3115	35773	1232	jaune	66
3116	24610	1232	jaune	81
3117	85696	1232	jaune	82
3118	57535	1232	jaune	95
3119	77224	1232	jaune	95
3120	25131	1232	jaune	99
3121	78056	1232	jaune	100
3122	35705	1233	jaune	60
3123	17688	1233	jaune	87
3124	34822	1234	jaune	15
3125	59727	1234	jaune	38
3126	54517	1235	jaune	32
3127	42160	1235	jaune	47
3128	17099	1235	jaune	88
3129	47321	1236	jaune	76
3130	7670	1237	jaune	90
3131	95766	1237	jaune	116
3132	64292	1238	jaune	44
3133	99025	1239	jaune	77
3134	26068	1239	jaune	90
3135	25131	1240	jaune	43
3136	56868	1240	jaune	59
3137	40137	1241	jaune	25
3138	79215	1241	jaune	31
3139	2305	1241	jaune	68
3140	76060	1241	jaune	77
3141	46461	1241	jaune	117
3142	74111	1242	jaune	43
3143	73712	1242	jaune	43
3144	79650	1242	jaune	45
3145	95036	1242	jaune	47
3146	27540	1242	jaune	76
3147	23070	1242	jaune	76
3148	10326	1242	jaune	88
3149	27582	1242	jaune	89
3150	14758	1242	jaune	100
3151	49114	1242	jaune	102
3152	44799	1242	jaune	91
3153	91431	1242	jaune	109
3154	29298	1242	jaune	112
3155	52013	1243	jaune	70
3156	89266	1243	jaune	87
3157	5216	1243	rouge	91
3158	90908	1244	jaune	43
3159	97778	1244	jaune	46
3160	9867	1244	jaune	82
3161	2465	1244	jaune	90
3162	99988	1245	jaune	32
3163	7670	1245	jaune	32
3164	79650	1245	jaune	68
3165	49114	1245	jaune	71
3166	59033	1246	jaune	27
3167	40619	1247	jaune	69
3168	23330	1247	jaune	84
3169	10739	1248	jaune	52
3170	57401	1248	jaune	55
3171	13613	1248	jaune	87
3172	89750	1248	jaune	95
3173	73712	1248	jaune	98
3174	27582	1248	jaune	114
3175	91431	1248	jaune	116
\.


--
-- Data for Name: gere; Type: TABLE DATA; Schema: public; Owner: wcuser
--

COPY public.gere (match_id, arbitre_principal_id, arbitre_secondaire1_id, arbitre_secondaire2_id, arbitre_secondaire3_id) FROM stdin;
382	204	884	1023	1248
1	5	1295	569	1127
2	6	1160	631	1390
3	9	515	1388	1024
4	11	1253	1021	1191
5	3	589	895	703
6	2	1151	1193	1284
7	7	693	1089	1034
8	6	1023	719	1405
9	4	621	1121	1187
10	9	1325	1266	613
11	8	537	758	1123
12	1	772	809	593
13	10	552	580	807
14	3	1355	711	976
15	4	1391	738	732
16	4	709	1074	1396
17	3	898	888	595
18	4	965	1126	677
19	21	1388	864	724
20	4	1171	843	612
21	19	701	1407	1291
22	13	947	893	1326
23	20	871	1157	1338
24	15	788	806	1055
25	16	674	1237	1396
26	18	669	1296	814
27	19	794	647	1127
28	14	1099	507	1291
29	13	590	649	1296
30	12	959	535	1072
31	20	1235	972	626
32	13	1206	760	1165
33	18	635	523	1254
34	17	1179	770	1397
35	18	1084	721	771
36	4	983	1400	513
37	26	742	1212	1023
38	28	1000	1002	852
39	23	1219	1078	1213
40	14	623	1290	674
41	18	838	1366	591
42	25	793	1233	651
43	15	960	714	973
44	18	1398	796	1153
45	27	499	841	1122
46	13	1035	1155	731
47	12	761	885	1389
48	24	1383	765	1341
49	22	769	1267	1273
50	25	877	1138	1058
51	28	902	497	752
52	4	725	949	664
53	22	815	1362	624
54	39	825	1308	1298
55	32	1157	678	920
56	40	1395	1068	906
57	41	890	1032	1264
58	36	1284	1292	935
59	29	797	812	882
60	35	1149	736	793
61	37	1330	1097	1051
62	30	1031	749	824
63	38	1246	1071	1176
64	34	792	1311	657
65	33	1142	852	691
66	32	619	1321	695
67	31	851	1215	859
68	39	899	1260	945
69	18	527	697	1164
70	31	502	855	943
71	34	517	646	1219
72	35	888	1294	1010
73	32	497	1141	742
74	40	683	721	1257
75	39	1211	595	871
76	53	814	601	555
77	34	1029	1237	556
78	45	1135	841	1272
79	31	1157	953	678
80	41	570	1201	1152
81	52	1170	1056	939
82	43	683	700	960
83	49	955	978	1024
84	48	1116	619	833
85	44	506	623	622
86	50	584	693	1251
87	42	849	1285	806
88	46	826	558	626
89	47	1310	1317	1202
90	51	1000	863	1234
91	54	800	841	862
92	52	1295	840	686
93	34	501	730	596
94	44	1148	993	903
95	51	673	1075	1196
96	31	1005	847	1395
97	54	838	1357	587
98	34	1234	1294	1341
99	48	1153	501	1135
100	53	1407	632	642
101	46	1026	572	992
102	65	585	854	631
103	35	1258	1022	1220
104	69	1202	971	1318
105	61	627	940	1176
106	53	1107	1013	828
107	58	818	555	1378
108	62	513	965	1028
109	54	1288	1040	1315
110	55	1408	790	509
111	31	520	1200	863
112	48	575	814	1286
113	34	1002	672	1003
114	64	857	660	494
115	59	1187	1102	748
116	63	1172	1168	1229
117	67	1274	972	629
118	70	1166	1221	953
119	31	1274	1388	999
120	57	538	788	1382
121	68	1170	1089	869
122	66	1314	1281	1257
123	60	526	766	868
124	62	1009	1296	845
125	56	1222	651	725
126	62	1396	1160	677
127	65	728	875	670
128	59	860	1080	776
129	69	1279	534	549
130	61	506	1196	1372
131	35	575	629	961
132	53	787	708	1295
133	34	976	1066	1362
134	54	1191	652	532
135	68	823	613	622
136	62	657	901	1406
137	76	962	573	683
138	71	1384	548	791
139	75	757	1065	502
140	61	1010	1242	1183
141	59	1014	660	699
142	74	610	767	1394
143	51	535	1268	573
144	79	1038	894	569
145	78	863	1358	1402
146	71	997	655	1119
147	82	617	936	875
148	65	527	537	1299
149	77	1193	640	1029
150	79	792	895	1127
151	83	527	622	642
152	61	1018	906	975
153	80	1110	1162	895
154	74	1385	999	801
155	73	793	996	940
156	84	1065	558	1370
157	81	852	528	561
158	65	567	1129	1029
159	75	1120	1328	976
160	72	1296	786	716
161	82	1337	699	1350
162	79	553	1023	982
163	65	946	831	683
164	84	924	516	497
165	84	792	1125	720
166	75	845	1248	520
167	61	849	810	974
168	65	1067	502	608
169	54	672	582	1356
170	98	1363	1019	1328
171	100	892	806	1195
172	61	600	879	1176
173	86	902	952	962
174	99	792	900	1209
175	88	812	713	756
176	75	698	1176	625
177	78	883	645	1130
178	87	579	1094	1041
179	89	908	1372	1208
180	92	708	586	1212
181	101	1010	942	1345
182	58	1287	1105	732
183	93	526	1307	936
184	94	862	993	644
185	95	878	1097	1183
186	57	906	1323	768
187	97	863	701	1097
188	82	939	581	895
189	84	1330	1034	825
190	96	496	1082	785
191	91	1327	650	674
192	85	1339	519	674
193	93	668	901	1391
194	86	712	922	975
195	61	1186	829	1126
196	90	855	796	1349
197	94	1144	770	1115
198	82	833	1262	1298
199	89	1313	1086	581
200	75	1395	683	537
201	100	988	1335	636
202	74	681	676	760
203	109	715	1226	1144
204	116	752	1230	1299
205	114	546	919	1013
206	119	1230	1097	500
207	103	565	1172	578
208	120	1188	533	1307
209	117	504	559	824
210	105	1348	1027	687
211	104	595	1219	710
212	87	674	679	577
213	92	866	1306	1280
214	118	1179	1285	504
215	107	1164	1406	1325
216	113	533	1161	1126
217	106	862	890	1259
218	108	959	1166	1285
219	111	990	584	863
220	102	1355	676	1080
221	112	1165	952	579
222	121	992	1128	1145
223	110	1336	587	519
224	115	1171	722	669
225	109	705	811	897
226	117	1191	589	1173
227	120	1206	707	664
228	112	1201	817	842
229	113	979	1155	636
230	84	1021	1405	914
231	116	579	1247	749
232	105	537	1219	1166
233	117	824	583	925
234	123	1237	861	1381
235	131	760	914	1186
236	138	1255	570	1352
237	134	535	1140	515
238	133	514	1319	1243
239	129	977	611	602
240	140	1185	1373	856
241	130	1225	728	766
242	122	1112	699	1134
243	141	580	571	1102
244	125	535	641	831
245	119	695	1269	1061
246	143	703	1183	499
247	127	1270	919	1331
248	139	1125	948	1320
249	132	1111	514	1318
250	126	993	713	938
251	136	601	624	999
252	103	981	1129	598
253	124	1269	1332	901
254	128	600	1016	744
255	137	1130	1099	858
256	142	1179	651	673
257	96	1221	540	696
258	140	678	1170	1293
259	74	1337	1311	1354
260	103	836	1268	884
261	109	1314	1109	919
262	117	1034	1028	665
263	105	1028	1098	779
264	127	1247	981	1145
265	128	1409	969	1263
266	119	1026	518	943
267	100	1035	940	842
268	135	853	994	811
269	122	1360	603	1258
270	119	1063	872	636
271	112	1193	650	904
272	136	720	962	1282
273	152	869	774	1262
274	150	1265	925	864
275	133	1160	584	986
276	140	659	1062	1200
277	126	1232	1272	914
278	149	1137	723	1135
279	103	996	1360	1394
280	156	1136	1258	927
281	145	1388	1239	1120
282	148	1350	1126	787
283	147	649	877	630
284	151	1396	890	1114
285	158	1149	576	1265
286	131	720	1289	554
287	146	1106	1165	683
288	132	1103	762	628
289	153	746	653	896
290	107	689	927	887
291	161	564	825	854
292	144	529	1252	885
293	154	1036	1237	1344
294	128	683	1192	1386
295	152	1027	962	1045
296	155	986	1007	835
297	136	1043	1070	1105
298	149	525	504	503
299	157	1303	833	976
300	159	713	723	539
301	103	752	840	1003
302	133	825	986	1295
303	107	1409	1405	1246
304	156	746	1114	905
305	160	1205	712	1399
306	161	1290	1251	494
307	107	709	1080	984
308	151	594	1199	1241
309	170	1018	695	1154
310	190	977	972	839
311	179	1046	1277	536
312	193	835	697	710
313	162	1254	838	1326
314	187	1378	846	1371
315	177	549	1124	1073
316	150	544	1191	855
317	176	891	890	1102
318	166	978	1403	1102
319	172	813	641	1204
320	174	1359	815	850
321	173	776	1184	1181
322	178	705	689	820
323	185	932	1181	1114
324	186	1201	1405	577
325	183	626	1112	1295
326	163	569	1204	1096
327	175	1159	889	1067
328	147	907	896	513
329	180	860	831	1183
330	124	837	867	1069
331	188	568	819	1344
332	169	1227	1123	1163
333	191	623	952	1287
334	192	543	732	1210
335	136	1072	578	1139
336	171	897	909	1273
337	165	579	1120	910
338	181	906	808	935
339	182	947	561	1304
340	167	762	746	523
341	168	1296	1160	543
342	189	1208	516	1404
343	164	861	654	1230
344	184	625	497	1399
345	133	818	771	672
346	185	820	1150	1408
347	136	602	878	737
348	146	1327	968	533
349	158	1245	1261	516
350	190	1360	1398	706
351	191	633	688	570
352	167	1034	562	545
353	154	573	1342	1214
354	189	680	674	672
355	107	828	948	895
356	186	957	715	739
357	166	1327	1401	885
358	147	884	1023	953
359	150	1087	858	533
360	146	857	726	592
361	174	1357	1340	754
362	198	579	1090	893
363	218	843	1003	614
364	217	555	892	642
365	194	1394	668	1206
366	211	1042	590	1131
367	205	815	1084	1365
368	201	1106	651	1368
369	216	828	1351	512
370	214	985	1349	1185
371	170	497	706	1120
372	212	820	586	647
373	208	553	1062	1373
374	197	1090	1112	1128
375	195	1003	1048	1304
376	196	1305	912	1142
377	182	1344	1081	1271
378	206	749	1390	819
379	202	533	800	536
380	200	734	1310	1093
381	199	1355	1230	1313
383	207	1046	1298	920
384	210	974	588	691
385	219	1208	1252	556
386	222	543	901	960
387	223	1300	1274	1142
388	187	904	548	1106
389	213	1053	1063	880
390	171	792	1348	608
391	203	1215	1320	939
392	220	1341	789	736
393	221	663	945	841
394	209	1405	1310	625
395	186	1130	504	767
396	215	694	1221	976
397	197	637	550	1233
398	174	1200	848	880
399	216	1129	661	697
400	194	1361	1184	670
401	205	502	1124	895
402	213	1116	854	627
403	196	1150	1259	1042
404	208	769	569	975
405	207	1347	1230	599
406	204	516	710	1076
407	199	659	838	849
408	209	723	1210	837
409	194	948	913	1311
410	210	513	1139	832
411	202	1185	573	1090
412	197	569	681	1029
413	190	556	1252	830
414	166	1074	540	833
415	202	789	792	1266
416	239	637	1355	577
417	233	1081	924	1083
418	228	1390	1025	1335
419	232	1214	969	770
420	229	688	530	623
421	234	1376	643	614
422	231	1202	560	594
423	236	1215	1385	589
424	227	1002	667	732
425	174	1112	1146	1109
426	218	691	627	612
427	194	1172	1361	863
428	224	894	1354	1360
429	235	977	1223	774
430	237	714	1338	615
431	226	1135	1002	818
432	230	589	569	1187
433	213	1389	1343	1277
434	238	551	620	1139
435	209	1228	1375	983
436	225	932	1364	1124
437	219	829	1079	1083
438	239	1348	951	726
439	220	947	796	1075
440	221	731	937	661
441	196	1359	1030	1364
442	215	1037	607	509
443	227	1199	826	780
444	213	651	1154	956
445	229	884	1146	1005
446	228	1147	1170	794
447	233	1210	838	782
448	190	844	519	1407
449	228	634	1189	543
450	209	1259	634	1281
451	215	1131	1129	668
452	229	763	813	895
453	239	893	1222	1374
454	202	711	538	868
455	234	959	666	894
456	232	1154	808	671
457	233	846	798	794
458	219	517	535	1373
459	227	866	688	1350
460	224	1340	1335	634
461	190	1349	975	668
462	239	1287	973	624
463	215	1143	1263	580
464	224	830	1320	1089
465	241	809	1115	849
466	245	886	1204	1085
467	249	505	869	914
468	242	844	746	940
469	247	1081	682	690
470	240	1376	798	1193
471	241	1008	1148	664
472	243	849	551	1065
473	244	750	1359	1304
474	250	504	790	1155
475	246	1077	1408	988
476	240	630	496	1206
477	242	1355	758	870
478	247	1372	1092	1313
479	246	1406	1279	969
480	250	993	1277	582
481	245	906	990	737
482	243	1174	858	1172
483	244	635	800	782
484	247	577	1285	1058
485	245	1271	1347	790
486	249	635	1032	1202
487	243	925	915	954
488	241	679	866	553
489	248	1208	967	1007
490	250	622	1210	837
491	254	671	507	756
492	232	1232	1177	995
493	261	966	523	1105
494	269	890	891	1206
495	196	568	1009	1211
496	268	1192	613	516
497	266	1033	1153	1223
498	267	664	748	1073
499	262	1341	885	587
500	257	865	1365	854
501	251	792	1311	1309
502	256	1002	1289	1099
503	252	653	927	683
504	226	1408	926	1212
505	253	990	1048	968
506	260	751	1153	596
507	264	726	567	1393
508	233	1046	863	847
509	254	1212	639	1158
510	215	552	754	1093
511	263	1337	1320	826
512	258	913	894	1168
513	259	1384	760	597
514	255	1222	781	749
515	232	815	1217	565
516	269	838	1106	938
517	252	692	1217	1009
518	215	573	860	1099
519	261	503	644	1287
520	268	1386	1198	1283
521	196	550	1273	1086
522	266	634	613	775
523	260	736	936	964
524	267	1231	1176	1199
525	226	899	875	1387
526	264	962	705	675
527	233	697	1295	869
528	269	848	657	1249
529	263	599	1281	1379
530	265	1089	796	967
531	232	1345	1084	605
532	215	802	899	1266
533	254	708	1014	1142
534	196	596	1067	496
535	266	1089	505	611
536	252	1134	830	893
537	268	886	748	1057
538	258	717	524	1373
539	215	1024	583	947
540	268	1237	515	681
541	255	785	1297	601
542	266	1316	634	1090
543	277	1017	1164	969
544	272	773	937	816
545	278	675	1324	644
546	274	648	506	1087
547	280	725	786	1135
548	276	547	1088	1364
549	275	981	1100	1244
550	270	559	810	1368
551	281	1059	1078	947
552	273	1176	1327	1220
553	279	602	1188	610
554	271	735	1236	1305
555	274	540	1189	1129
556	277	806	1187	1188
557	276	806	834	904
558	279	656	805	1225
559	273	650	827	629
560	281	768	939	614
561	273	1237	1181	1231
562	281	824	1328	1288
563	280	1311	725	952
564	272	1084	553	1014
565	274	1025	521	572
566	277	772	1356	1333
567	272	622	1298	618
568	276	1055	1301	882
569	292	1095	764	974
570	281	526	1092	657
571	287	1101	1182	675
572	293	1183	1408	1092
573	302	497	1052	1145
574	288	1165	1390	1150
575	304	654	1071	910
576	283	662	1207	1182
577	286	730	623	1012
578	289	1368	1325	767
579	269	946	1080	759
580	267	719	938	518
581	298	1129	857	953
582	300	1404	1139	587
583	262	1050	1221	990
584	285	684	710	823
585	306	1217	1159	712
586	65	872	580	743
587	282	824	801	1143
588	295	901	1255	1123
589	247	700	941	788
590	254	594	525	994
591	305	730	1052	1004
592	296	835	780	944
593	303	1405	1064	1273
594	290	1031	583	647
595	307	962	776	1264
596	299	1096	1059	1319
597	301	505	582	1064
598	297	1140	1316	933
599	294	503	1380	968
600	284	1268	610	743
601	306	583	1401	1280
602	291	1064	786	746
603	283	1363	1298	1043
604	255	1157	1230	498
605	289	1330	1045	950
606	305	517	664	641
607	281	561	997	1161
608	269	943	534	843
609	304	879	846	1372
610	302	1184	1180	759
611	293	971	1365	1293
612	282	704	1262	1282
613	285	992	668	1194
614	286	1082	1119	1152
615	254	1200	500	575
616	295	1207	751	852
617	294	521	1377	667
618	284	730	946	677
619	255	1269	828	678
620	297	1400	637	1286
621	298	776	751	1251
622	292	708	937	907
623	288	1346	523	1283
624	299	1211	1122	1397
625	290	1387	537	1024
626	282	854	992	1280
627	254	964	1196	989
628	301	517	1032	1290
629	255	585	772	849
630	292	1119	605	1186
631	293	709	1353	626
632	285	518	987	953
633	272	1346	941	644
634	320	692	898	1172
635	318	1162	734	989
636	279	953	1020	562
637	308	709	1340	922
638	321	1123	849	1186
639	310	1348	811	643
640	319	494	997	784
641	313	1333	1250	695
642	316	1057	702	888
643	311	887	837	566
644	312	1390	1137	911
645	315	669	1276	1200
646	317	928	1002	1248
647	318	1109	499	1279
648	314	1231	689	935
649	321	1180	1101	1190
650	313	1279	621	1364
651	272	931	1248	761
652	309	1376	1124	985
653	314	684	1310	1348
654	279	676	965	1335
655	308	1127	621	782
656	310	830	797	1162
657	318	601	1317	791
658	314	587	695	1405
659	317	616	1079	814
660	320	1099	662	820
661	310	1150	1319	815
662	272	1292	505	1379
663	314	839	584	541
664	318	560	1348	655
665	255	943	1402	1321
666	330	1235	965	574
667	333	1330	1165	561
668	322	636	1346	687
669	348	616	1298	740
670	336	1304	1127	648
671	346	1247	1265	1243
672	327	1337	1279	579
673	242	1146	608	661
674	331	568	1224	873
675	328	1064	1092	1341
676	347	1022	1376	1020
677	334	1207	1171	914
678	343	1141	1036	1126
679	341	714	855	721
680	337	945	1240	750
681	299	1401	1388	1288
682	323	602	1378	590
683	329	1160	1281	1168
684	342	1225	882	1409
685	339	640	1272	677
686	282	810	801	1062
687	289	1268	963	931
688	344	894	852	979
689	340	854	936	552
690	326	914	1302	536
691	325	665	1197	787
692	324	883	604	1368
693	335	559	1214	1035
694	297	878	971	1375
695	345	1384	900	581
696	290	1331	1363	1186
697	298	1316	1007	1164
698	349	573	830	873
699	332	942	1111	1125
700	338	1226	1378	658
701	328	609	882	724
702	255	710	501	812
703	342	603	1211	1115
704	333	1164	629	890
705	282	1371	821	933
706	343	885	899	1399
707	334	1145	1205	689
708	346	1358	1184	802
709	299	602	895	1096
710	348	562	1266	625
711	242	586	844	1033
712	344	1044	559	951
713	323	1290	773	762
714	335	1145	654	495
715	322	999	1184	663
716	326	683	1301	657
717	298	1211	1224	1231
718	341	495	1045	953
719	289	1308	635	1324
720	337	1379	669	1007
721	342	707	1251	748
722	290	750	700	1191
723	282	1328	947	830
724	343	1124	1219	1001
725	297	891	1264	975
726	299	624	657	1050
727	333	1335	884	1290
728	289	993	1254	904
729	319	1265	517	906
730	318	794	858	1212
731	314	1240	1244	591
732	310	1062	1301	697
733	354	877	1259	745
734	316	888	1369	633
735	308	786	1379	1173
736	272	802	623	818
737	350	1165	1124	928
738	353	713	651	1017
739	354	751	935	1395
740	318	1252	834	662
741	319	1120	1387	646
742	316	1220	1068	1398
743	310	1002	519	1158
744	352	1151	791	860
745	351	727	538	630
746	316	989	1287	544
747	308	879	497	619
748	314	1148	822	872
749	272	1375	1251	1062
750	353	1194	1177	682
751	350	1135	1030	1394
752	352	880	1379	1217
753	354	500	982	566
754	318	1142	930	679
755	314	1347	1333	1171
756	319	823	828	821
757	272	673	986	816
758	310	1013	935	777
759	316	1080	1188	1172
760	351	1407	1144	684
761	360	1117	987	828
762	330	1218	912	1172
763	366	528	975	1052
764	363	1094	1236	1068
765	359	802	630	1174
766	335	1089	557	881
767	367	898	540	826
768	362	915	1183	1165
769	355	1007	1322	1325
770	356	598	790	1298
771	346	736	759	538
772	340	1297	831	576
773	361	879	1371	1014
774	357	1313	986	664
775	358	601	1407	777
776	345	936	1148	1344
777	364	1257	1297	753
778	324	1371	597	1287
779	330	596	1178	518
780	336	975	1060	956
781	367	1123	1305	1170
782	343	1031	1131	1144
783	363	1077	585	794
784	365	832	1147	766
785	360	691	863	804
786	362	509	1180	1359
787	359	1333	1170	1271
788	335	1243	1334	609
789	357	849	1132	914
790	356	1193	643	1387
791	340	1094	1029	1071
792	346	1135	601	1200
793	363	1201	1116	571
794	361	1254	1299	545
795	367	881	1118	854
796	358	691	892	1240
797	345	697	1364	1402
798	336	1383	636	1237
799	366	1012	732	566
800	364	999	1221	1294
801	357	1100	979	1287
802	335	665	1206	936
803	340	1230	574	1324
804	365	1301	716	830
805	324	858	993	553
806	356	976	762	546
807	360	606	1142	558
808	362	1372	535	766
809	346	1015	596	656
810	358	1189	1039	1314
811	359	645	961	1233
812	361	725	1276	557
813	364	501	569	885
814	357	1014	640	1406
815	336	1143	1403	1347
816	367	682	818	629
817	336	1370	1395	963
818	359	1355	1165	553
819	360	807	756	745
820	364	1066	1004	821
821	357	706	1114	1017
822	362	818	954	886
823	330	590	713	1189
824	360	815	546	1376
825	316	700	781	917
826	318	772	804	1271
827	319	1268	673	1261
828	375	1250	969	1386
829	370	804	1128	790
830	374	813	816	595
831	368	999	910	936
832	372	1223	576	582
833	371	791	1077	1164
834	373	803	1268	987
835	377	627	1322	932
836	316	697	858	949
837	318	1126	1211	1339
838	376	565	917	1114
839	375	956	792	1377
840	369	615	927	707
841	372	1034	1158	496
842	370	1169	1390	701
843	376	626	1068	1223
844	368	620	771	1370
845	373	1336	1118	1145
846	369	1346	1278	709
847	319	1351	1111	1268
848	371	846	917	499
849	316	802	892	684
850	377	892	771	526
851	373	1214	777	695
852	368	1155	735	1245
853	371	689	1393	1136
854	318	1023	994	604
855	373	902	1236	1116
856	316	1345	848	1271
857	384	498	650	563
858	388	1170	1039	688
859	383	1288	622	1040
860	390	661	730	935
861	346	922	1388	869
862	323	692	1239	797
863	379	891	1124	795
864	366	932	497	609
865	386	1375	1016	634
866	380	962	1285	1400
867	357	1313	575	759
868	382	963	993	1012
869	362	1137	530	495
870	385	613	777	1349
871	387	1226	937	647
872	392	805	1321	1027
873	358	955	995	773
874	359	1002	871	660
875	343	885	854	870
876	378	1104	764	1316
877	391	755	1304	509
878	381	1327	1029	594
879	384	1146	879	1232
880	379	611	1021	1283
881	367	663	497	1126
882	362	1095	1183	858
883	387	618	1044	1186
884	323	1034	955	1067
885	386	692	1111	951
886	389	769	1168	505
887	378	855	555	1129
888	388	886	540	1228
889	343	522	934	949
890	385	1283	1250	1130
891	384	966	1038	810
892	380	1239	665	889
893	390	1043	1401	600
894	359	651	974	1036
895	362	557	1171	650
896	346	1291	1099	1077
897	388	555	1303	1212
898	392	1345	882	864
899	389	1115	784	1070
900	382	580	1260	1224
901	391	1191	1130	875
902	357	1339	1195	1189
903	366	938	1043	875
904	379	671	1095	1188
905	390	1165	592	934
906	385	1202	647	1313
907	362	911	534	556
908	367	950	574	1140
909	391	1011	592	575
910	392	1171	1148	755
911	359	828	634	656
912	379	1244	561	1042
913	388	579	1049	1301
914	380	959	1221	1071
915	384	944	865	879
916	323	495	1000	691
917	384	566	623	1177
918	385	1341	502	1311
919	357	1307	1398	899
920	392	1139	787	1320
921	319	741	755	1231
922	399	1331	1378	1181
923	398	762	648	657
924	402	1236	663	756
925	396	639	952	768
926	403	1147	1314	914
927	393	1235	896	1389
928	377	986	559	1353
929	397	524	1318	1236
930	395	644	1285	998
931	401	1123	867	1012
932	400	1247	1225	603
933	394	544	506	942
934	371	627	1079	1043
935	373	1111	686	1394
936	319	899	848	1119
937	396	1363	990	1397
938	377	653	938	946
939	404	798	498	1215
940	398	553	849	734
941	394	995	641	1384
942	403	1310	793	1255
943	401	846	652	495
944	397	638	1288	839
945	377	1303	1198	1110
946	393	809	785	927
947	402	1111	494	1342
948	399	1324	1128	1265
949	398	521	1315	834
950	396	851	1245	752
951	319	1155	1231	844
952	403	664	857	1028
953	388	1008	1056	837
954	421	516	1217	593
955	420	531	1071	1166
956	408	592	870	677
957	411	589	710	1368
958	406	1111	530	676
959	413	748	1101	783
960	416	1018	1097	1230
961	384	1149	805	892
962	419	963	1362	1075
963	405	1337	636	1078
964	414	1316	904	570
965	424	975	1127	1366
966	409	1141	1046	652
967	366	730	853	676
968	407	1103	617	780
969	417	996	991	1084
970	412	691	1382	909
971	411	1366	749	1227
972	418	760	1254	1118
973	392	703	1175	608
974	423	1278	759	1406
975	405	985	1404	1237
976	416	1027	608	723
977	413	1217	848	1273
978	425	1350	810	699
979	414	542	928	858
980	419	1394	1115	500
981	415	1319	692	655
982	406	925	1358	1409
983	421	1219	634	1015
984	417	1255	1269	640
985	422	625	1287	494
986	410	814	854	830
987	409	808	1154	843
988	384	1121	823	1015
989	412	1009	923	1070
990	366	795	611	515
991	418	1086	1120	1068
992	424	553	1084	1051
993	423	832	721	876
994	420	715	730	1323
995	417	842	1378	1362
996	408	1116	757	1183
997	422	782	1273	829
998	384	516	611	932
999	407	705	1404	1169
1000	425	560	1019	637
1001	392	1347	1274	891
1002	413	523	1026	918
1003	418	772	1116	1379
1004	425	1036	1062	853
1005	411	961	974	733
1006	419	767	642	1245
1007	409	1311	1365	558
1008	412	899	1296	1299
1009	417	676	1342	505
1010	423	668	1330	1005
1011	420	687	1091	751
1012	384	600	918	786
1013	366	944	1359	529
1014	407	999	520	997
1015	412	605	575	920
1016	420	1084	724	659
1017	438	562	851	517
1018	393	1181	954	641
1019	432	1333	842	893
1020	396	794	1298	523
1021	440	1036	666	549
1022	433	898	510	621
1023	442	801	1107	1094
1024	443	519	733	812
1025	437	1006	1184	778
1026	428	920	547	1390
1027	400	572	1297	536
1028	441	1105	1390	1167
1029	436	1383	1077	1111
1030	426	582	1292	757
1031	403	787	1338	1107
1032	429	944	969	1136
1033	431	525	1173	1262
1034	430	850	978	546
1035	434	631	1307	813
1036	445	649	1113	1096
1037	439	547	667	1386
1038	396	1260	1054	525
1039	432	967	920	944
1040	444	1166	1044	1200
1041	435	1089	513	883
1042	428	692	676	1210
1043	433	1409	1264	1242
1044	440	792	1156	1044
1045	442	1278	967	1220
1046	427	593	963	644
1047	438	822	557	718
1048	443	691	1260	947
1049	396	1301	1367	802
1050	445	775	640	1030
1051	432	1178	746	1282
1052	437	1304	996	1142
1053	440	1151	1264	1114
1054	403	693	496	750
1055	426	1002	1114	928
1056	428	1172	1183	887
1057	432	730	743	958
1058	441	1077	765	628
1059	430	1138	986	1223
1060	443	1185	665	798
1061	396	886	1331	641
1062	444	864	736	590
1063	438	1091	979	1055
1064	442	554	1112	1229
1065	426	610	1388	588
1066	432	718	1255	1376
1067	440	497	1188	759
1068	438	723	532	1068
1069	417	790	669	868
1070	413	1269	1238	1271
1071	407	796	1329	752
1072	458	1202	1034	694
1073	448	1155	1263	628
1074	454	1150	1125	695
1075	410	541	1293	972
1076	419	1167	752	1388
1077	449	1178	758	1082
1078	450	1252	1090	571
1079	457	1036	570	690
1080	405	1022	905	694
1081	459	994	1084	548
1082	421	1359	985	931
1083	460	781	1215	1177
1084	422	1273	1072	892
1085	446	543	503	1383
1086	411	1309	599	1054
1087	461	571	521	1266
1088	448	572	1382	1394
1089	456	499	1376	943
1090	452	1142	596	1152
1091	384	1027	1025	938
1092	413	993	614	1290
1093	447	1262	1333	956
1094	406	1090	977	1180
1095	455	1002	1010	1240
1096	414	919	636	582
1097	454	821	1209	920
1098	451	562	1009	994
1099	458	775	1120	1139
1100	457	1328	673	706
1101	421	1066	1331	1294
1102	449	1258	629	847
1103	384	1283	599	943
1104	446	743	1058	1044
1105	453	1135	952	747
1106	419	1117	683	659
1107	456	742	916	1236
1108	407	1094	908	1118
1109	411	1216	1189	1116
1110	417	1054	1291	1216
1111	450	572	1196	1066
1112	461	585	1047	536
1113	459	1332	1163	1329
1114	414	1249	1219	655
1115	460	931	1302	584
1116	422	761	1053	729
1117	450	810	1234	1161
1118	457	773	1179	541
1119	413	626	660	929
1120	417	1192	898	806
1121	458	586	1277	739
1122	449	667	1300	1256
1123	460	1221	735	616
1124	411	1146	840	815
1125	417	1362	919	998
1126	414	984	880	1188
1127	413	1258	1239	817
1128	419	758	995	543
1129	448	909	602	1324
1130	407	1353	949	842
1131	450	643	659	660
1132	417	522	765	1366
1133	442	569	524	673
1134	464	880	921	1170
1135	466	567	750	773
1136	469	750	551	734
1137	427	517	583	1391
1138	468	1293	729	1288
1139	462	777	498	580
1140	430	711	1200	1266
1141	440	754	1034	1353
1142	463	504	893	1297
1143	443	862	1049	786
1144	467	614	563	1194
1145	471	759	1280	502
1146	438	804	523	810
1147	403	1026	839	1248
1148	441	998	895	1321
1149	433	630	564	1063
1150	473	757	500	945
1151	432	510	1318	500
1152	439	801	815	974
1153	472	1071	985	1165
1154	474	907	780	572
1155	470	1302	1106	1185
1156	468	1391	1213	686
1157	463	618	981	1314
1158	465	1123	568	848
1159	427	1145	724	767
1160	464	1033	1378	1255
1161	443	1267	604	553
1162	433	852	1244	1138
1163	442	570	1068	967
1164	440	1305	532	880
1165	438	1257	1042	850
1166	430	821	1352	1051
1167	471	994	1351	1218
1168	432	710	944	624
1169	474	778	705	1268
1170	468	639	1009	1130
1171	439	861	754	798
1172	464	624	631	1091
1173	433	1118	1137	1178
1174	469	610	672	794
1175	463	1263	857	532
1176	427	896	813	635
1177	443	1164	648	784
1178	438	1179	1271	596
1179	442	1219	886	1012
1180	430	1211	932	831
1181	463	1157	679	1224
1182	464	737	1022	772
1183	471	761	549	570
1184	430	921	1191	713
1185	486	711	910	1022
1186	478	883	1095	897
1187	488	1215	616	1207
1188	475	1157	771	988
1189	493	685	536	923
1190	457	542	663	1161
1191	477	1373	494	719
1192	482	798	773	1334
1193	487	523	934	743
1194	476	706	952	1074
1195	452	681	1111	1334
1196	459	610	573	910
1197	491	1234	1254	636
1198	461	1168	715	1116
1199	479	901	949	799
1200	450	495	1009	1269
1201	480	1211	561	696
1202	456	1243	662	1343
1203	481	1187	1388	1104
1204	492	1237	508	1044
1205	489	683	760	1213
1206	488	630	1145	1111
1207	454	1148	1044	1380
1208	486	1097	1230	1106
1209	485	894	1308	813
1210	457	1246	1271	657
1211	484	1293	921	793
1212	483	901	638	801
1213	452	622	865	1013
1214	490	988	927	674
1215	476	596	792	1315
1216	450	1252	984	1370
1217	461	517	762	837
1218	410	1220	1306	1375
1219	456	1352	706	1293
1220	493	1322	1399	1326
1221	481	661	1351	1288
1222	447	1349	1128	1093
1223	483	934	1333	1083
1224	485	850	822	710
1225	478	1289	904	921
1226	490	1107	1272	1246
1227	430	629	615	824
1228	482	940	703	801
1229	489	669	1275	1379
1230	491	1188	1210	1388
1231	479	778	984	1056
1232	487	1077	588	1272
1233	488	1278	1343	768
1234	454	722	1001	514
1235	492	1173	1093	1210
1236	476	910	877	1023
1237	479	516	946	845
1238	461	983	1088	1367
1239	487	826	769	840
1240	457	1263	1374	1380
1241	485	1367	794	1015
1242	456	884	558	704
1243	491	944	1037	609
1244	488	942	713	778
1245	486	593	775	953
1246	457	611	1092	1239
1247	475	685	1025	1022
1248	454	1194	960	757
\.


--
-- Data for Name: joue; Type: TABLE DATA; Schema: public; Owner: wcuser
--

COPY public.joue (id_match, id_equipea, id_equipeb) FROM stdin;
382	204	196
1	6	7
2	11	2
3	13	4
4	10	9
5	1	6
6	5	7
7	13	3
8	11	8
9	12	9
10	5	6
11	1	7
12	4	3
13	8	2
14	12	10
15	1	5
16	1	11
17	12	13
18	12	1
19	15	20
20	18	25
21	21	16
22	22	19
23	23	29
24	26	17
25	27	14
26	28	24
27	15	22
28	18	28
29	21	27
30	23	26
31	23	26
32	18	21
33	23	15
34	21	15
35	23	18
36	44	36
37	32	42
38	35	30
39	37	34
40	38	40
41	31	41
42	33	39
43	32	42
44	44	36
45	31	33
46	37	44
47	38	35
48	43	32
49	31	33
50	37	43
51	38	31
52	31	43
53	38	37
54	46	50
55	57	54
56	48	47
57	52	55
58	53	49
59	46	54
60	57	50
61	52	47
62	55	48
63	53	51
64	46	57
65	47	55
66	52	48
67	49	51
68	56	45
69	54	50
70	46	53
71	56	52
72	46	52
73	56	53
74	53	52
75	56	46
76	60	66
77	73	63
78	58	67
79	71	61
80	69	65
81	64	68
82	72	70
83	62	59
84	71	67
85	60	73
86	58	61
87	63	66
88	64	72
89	70	68
90	65	59
91	62	69
92	72	70
93	69	65
94	58	69
95	71	62
96	64	60
97	72	73
98	64	71
99	72	58
100	58	71
101	72	64
102	86	81
103	74	88
104	82	77
105	79	83
106	89	84
107	80	87
108	76	75
109	85	78
110	74	82
111	88	77
112	83	84
113	89	79
114	81	87
115	76	78
116	85	75
117	86	80
118	86	87
119	77	74
120	88	82
121	79	84
122	83	89
123	80	81
124	76	85
125	78	75
126	82	77
127	87	80
128	85	78
129	76	87
130	79	82
131	86	85
132	88	89
133	76	79
134	86	88
135	79	88
136	76	86
137	103	94
138	93	102
139	91	99
140	90	92
141	100	105
142	104	98
143	95	101
144	97	96
145	105	103
146	93	98
147	91	95
148	96	90
149	100	94
150	104	102
151	101	99
152	97	92
153	100	103
154	104	93
155	91	101
156	97	90
157	105	94
158	98	102
159	99	95
160	96	92
161	91	96
162	93	100
163	95	97
164	105	104
165	91	93
166	95	105
167	93	105
168	91	95
169	110	120
170	121	119
171	107	108
172	117	115
173	111	114
174	106	118
175	116	112
176	113	109
177	120	111
178	118	119
179	112	107
180	109	115
181	106	121
182	116	108
183	117	113
184	110	114
185	114	120
186	106	119
187	116	107
188	115	113
189	110	111
190	121	118
191	112	108
192	117	109
193	110	106
194	116	115
195	117	112
196	121	120
197	121	117
198	110	116
199	116	117
200	110	121
201	130	134
202	136	128
203	127	133
204	132	124
205	122	126
206	129	135
207	123	125
208	137	131
209	134	122
210	136	129
211	133	125
212	132	131
213	130	126
214	135	128
215	123	127
216	137	124
217	134	126
218	135	136
219	123	133
220	137	132
221	130	122
222	129	128
223	127	125
224	124	131
225	123	132
226	129	130
227	134	136
228	137	127
229	123	136
230	129	137
231	137	136
232	123	129
233	140	152
234	151	142
235	143	139
236	153	148
237	149	141
238	150	146
239	145	144
240	147	138
241	139	151
242	142	143
243	148	140
244	152	153
245	141	150
246	146	149
247	138	145
248	144	147
249	139	142
250	148	152
251	153	140
252	143	151
253	141	146
254	149	150
255	138	144
256	147	145
257	152	151
258	140	143
259	146	138
260	149	147
261	138	140
262	143	146
263	147	152
264	151	149
265	147	151
266	138	143
267	146	140
268	149	152
269	140	147
270	146	151
271	169	164
272	160	157
273	168	161
274	154	158
275	155	166
276	156	167
277	162	159
278	163	165
279	160	158
280	164	168
281	169	161
282	154	157
283	155	167
284	156	166
285	162	163
286	165	159
287	157	158
288	164	161
289	169	168
290	154	160
291	156	155
292	166	167
293	163	159
294	165	162
295	155	162
296	160	169
297	156	163
298	154	164
299	163	164
300	160	155
301	162	169
302	154	156
303	155	169
304	160	162
305	156	164
306	154	163
307	156	160
308	154	162
309	171	173
310	183	188
311	174	190
312	187	175
313	182	178
314	189	185
315	192	170
316	179	180
317	191	181
318	176	172
319	177	184
320	193	186
321	183	187
322	171	182
323	174	189
324	188	175
325	173	178
326	190	185
327	192	176
328	179	177
329	191	193
330	170	172
331	180	184
332	181	186
333	188	187
334	173	182
335	190	189
336	183	175
337	171	178
338	174	185
339	170	176
340	180	177
341	181	193
342	192	172
343	179	184
344	191	186
345	172	180
346	188	173
347	183	171
348	192	179
349	172	186
350	173	190
351	171	174
352	192	191
353	180	186
354	190	188
355	183	174
356	191	179
357	188	183
358	192	180
359	188	180
360	183	192
361	198	205
362	215	197
363	199	202
364	195	213
365	214	203
366	207	210
367	196	206
368	194	208
369	211	201
370	209	204
371	216	217
372	212	200
373	205	195
374	202	214
375	213	198
376	203	199
377	197	194
378	201	207
379	206	209
380	208	215
381	210	211
383	217	212
384	200	216
385	203	202
386	214	199
387	195	198
388	213	205
389	204	206
390	209	196
391	201	210
392	211	207
393	194	215
394	208	197
395	200	217
396	212	216
397	206	198
398	214	196
399	197	210
400	195	216
401	205	202
402	207	217
403	201	209
404	200	215
405	197	202
406	217	206
407	195	201
408	215	196
409	202	217
410	195	196
411	196	202
412	195	217
413	218	222
414	234	231
415	237	223
416	228	219
417	238	225
418	221	236
419	240	241
420	224	232
421	227	230
422	220	233
423	229	226
424	239	235
425	218	234
426	222	231
427	241	223
428	228	238
429	219	225
430	240	237
431	221	224
432	236	232
433	227	229
434	230	226
435	220	239
436	233	235
437	218	231
438	222	234
439	240	223
440	241	237
441	219	238
442	228	225
443	221	232
444	236	224
445	220	235
446	233	239
447	227	226
448	230	229
449	222	223
450	225	224
451	221	218
452	240	229
453	230	231
454	228	239
455	235	241
456	227	220
457	218	241
458	230	228
459	225	240
460	222	227
461	218	228
462	240	227
463	228	227
464	240	218
465	243	251
466	246	250
467	245	249
468	248	242
469	252	253
470	244	247
471	251	249
472	247	250
473	243	245
474	242	253
475	248	252
476	244	246
477	242	252
478	248	253
479	243	249
480	251	245
481	244	250
482	247	246
483	245	246
484	243	252
485	251	247
486	253	244
487	252	251
488	246	253
489	252	246
490	251	253
491	261	256
492	274	273
493	277	276
494	263	269
495	260	270
496	255	265
497	268	264
498	259	275
499	257	271
500	266	272
501	254	262
502	261	274
503	267	258
504	270	276
505	277	260
506	263	268
507	273	256
508	264	269
509	257	259
510	275	271
511	255	266
512	272	265
513	254	267
514	258	262
515	276	260
516	277	270
517	256	274
518	261	273
519	263	264
520	269	268
521	271	259
522	257	275
523	255	272
524	265	266
525	254	258
526	262	267
527	261	255
528	274	276
529	272	275
530	270	254
531	266	269
532	257	277
533	267	263
534	264	258
535	263	274
536	266	257
537	258	261
538	270	275
539	258	263
540	275	257
541	275	258
542	257	263
543	284	285
544	288	279
545	283	280
546	287	286
547	282	278
548	289	281
549	279	285
550	288	284
551	286	280
552	287	283
553	281	278
554	289	282
555	279	284
556	288	285
557	286	283
558	287	280
559	281	282
560	289	278
561	285	289
562	287	282
563	284	283
564	288	281
565	289	287
566	284	281
567	281	289
568	284	287
569	293	315
570	308	311
571	304	296
572	295	291
573	312	294
574	314	299
575	301	316
576	318	310
577	317	307
578	309	292
579	290	306
580	321	303
581	305	298
582	300	319
583	313	297
584	302	320
585	315	311
586	293	308
587	296	291
588	304	295
589	316	299
590	301	314
591	310	294
592	318	312
593	306	298
594	292	307
595	309	317
596	302	321
597	290	305
598	320	303
599	297	319
600	313	300
601	296	295
602	304	291
603	293	311
604	315	308
605	301	299
606	316	314
607	310	312
608	318	294
609	292	317
610	309	307
611	302	303
612	320	321
613	290	298
614	306	305
615	297	300
616	313	319
617	304	311
618	293	296
619	301	312
620	310	299
621	302	307
622	309	321
623	313	298
624	290	300
625	304	301
626	293	299
627	309	290
628	302	298
629	293	309
630	301	298
631	309	298
632	293	301
633	337	326
634	325	336
635	323	331
636	330	324
637	327	329
638	334	335
639	333	332
640	322	328
641	330	335
642	334	324
643	322	336
644	325	328
645	323	329
646	333	326
647	337	332
648	327	331
649	324	335
650	325	322
651	328	336
652	334	330
653	327	323
654	332	326
655	331	329
656	337	333
657	325	335
658	334	336
659	337	327
660	323	332
661	337	323
662	334	325
663	323	334
664	337	325
665	348	360
666	357	341
667	369	345
668	349	359
669	338	353
670	354	362
671	347	365
672	364	361
673	344	352
674	340	367
675	350	346
676	342	343
677	351	339
678	363	355
679	358	366
680	368	356
681	349	357
682	345	360
683	341	359
684	348	369
685	365	353
686	364	354
687	338	347
688	362	361
689	350	344
690	340	342
691	352	346
692	343	367
693	351	358
694	363	368
695	366	339
696	356	355
697	345	348
698	360	369
699	341	349
700	359	357
701	353	347
702	365	338
703	361	354
704	362	364
705	343	340
706	367	342
707	346	344
708	352	350
709	339	358
710	366	351
711	355	368
712	356	363
713	349	354
714	345	347
715	365	360
716	364	357
717	352	368
718	340	339
719	351	367
720	363	350
721	347	340
722	349	368
723	364	363
724	360	367
725	349	363
726	340	367
727	363	367
728	349	340
729	381	375
730	379	380
731	376	373
732	378	370
733	385	384
734	372	383
735	371	382
736	374	377
737	381	372
738	376	378
739	375	383
740	373	370
741	377	382
742	384	380
743	374	371
744	385	379
745	375	372
746	383	381
747	370	376
748	373	378
749	384	379
750	380	385
751	377	371
752	374	382
753	372	384
754	385	381
755	376	382
756	374	373
757	385	376
758	384	373
759	385	373
760	376	384
761	396	390
762	405	393
763	394	404
764	414	411
765	387	400
766	408	403
767	402	398
768	386	406
769	388	401
770	417	392
771	399	397
772	409	413
773	395	412
774	389	391
775	410	416
776	415	407
777	396	405
778	393	390
779	394	414
780	411	404
781	387	408
782	403	400
783	402	386
784	406	398
785	392	397
786	399	417
787	401	391
788	389	388
789	395	409
790	413	412
791	407	416
792	410	415
793	390	405
794	393	396
795	404	414
796	411	394
797	398	386
798	406	402
799	400	408
800	403	387
801	392	399
802	397	417
803	391	388
804	401	389
805	407	410
806	416	415
807	412	409
808	413	395
809	396	411
810	387	402
811	394	393
812	406	403
813	399	388
814	412	416
815	389	397
816	410	395
817	396	387
818	399	416
819	394	406
820	389	395
821	396	399
822	406	395
823	396	406
824	399	395
825	425	418
826	433	430
827	427	424
828	429	432
829	426	419
830	428	420
831	431	421
832	422	423
833	418	427
834	432	433
835	424	425
836	430	429
837	421	426
838	423	428
839	419	431
840	420	422
841	424	418
842	425	427
843	429	433
844	430	432
845	419	421
846	431	426
847	420	423
848	422	428
849	425	430
850	433	424
851	431	422
852	420	419
853	425	431
854	433	420
855	431	433
856	425	420
857	460	450
858	465	442
859	461	445
860	435	453
861	441	464
862	434	459
863	457	444
864	443	436
865	451	440
866	449	438
867	447	455
868	452	458
869	448	456
870	437	454
871	446	439
872	462	463
873	460	465
874	435	461
875	445	453
876	442	450
877	443	457
878	459	464
879	441	434
880	451	449
881	444	436
882	438	440
883	458	455
884	447	452
885	437	448
886	456	454
887	439	463
888	462	446
889	442	460
890	450	465
891	445	435
892	453	461
893	459	441
894	464	434
895	436	457
896	444	443
897	455	452
898	458	447
899	438	451
900	440	449
901	454	448
902	456	437
903	439	462
904	463	446
905	465	461
906	464	444
907	443	441
908	435	450
909	451	458
910	437	439
911	455	449
912	462	456
913	451	437
914	465	444
915	435	443
916	455	462
917	465	451
918	443	462
919	465	443
920	451	462
921	477	472
922	473	468
923	474	476
924	475	470
925	469	480
926	481	478
927	479	471
928	467	466
929	468	472
930	473	477
931	474	475
932	476	470
933	478	480
934	481	469
935	466	471
936	467	479
937	470	474
938	476	475
939	468	477
940	472	473
941	466	479
942	471	467
943	478	469
944	480	481
945	470	472
946	473	474
947	480	466
948	467	481
949	472	481
950	474	480
951	480	472
952	474	481
953	487	492
954	504	488
955	510	505
956	489	484
957	490	498
958	513	491
959	494	501
960	502	503
961	511	493
962	495	499
963	483	486
964	496	507
965	500	506
966	497	512
967	485	482
968	487	504
969	508	509
970	484	505
971	510	489
972	488	492
973	490	502
974	513	494
975	503	498
976	501	491
977	511	495
978	499	493
979	483	500
980	496	497
981	506	486
982	485	508
983	509	482
984	512	507
985	484	510
986	505	489
987	488	487
988	492	504
989	491	494
990	501	513
991	503	490
992	498	502
993	486	500
994	506	483
995	499	511
996	493	495
997	507	497
998	512	496
999	482	508
1000	509	485
1001	487	489
1002	490	513
1003	505	504
1004	491	498
1005	495	506
1006	496	482
1007	483	511
1008	485	512
1009	495	496
1010	487	490
1011	483	485
1012	505	491
1013	487	496
1014	505	483
1015	487	505
1016	496	483
1017	517	518
1018	529	528
1019	531	536
1020	524	525
1021	534	530
1022	516	521
1023	537	514
1024	526	535
1025	523	522
1026	533	520
1027	519	527
1028	515	532
1029	518	528
1030	524	531
1031	517	529
1032	525	536
1033	535	521
1034	514	530
1035	526	516
1036	537	534
1037	523	519
1038	515	533
1039	522	527
1040	532	520
1041	536	524
1042	525	531
1043	518	529
1044	528	517
1045	535	516
1046	521	526
1047	530	537
1048	514	534
1049	522	519
1050	527	523
1051	532	533
1052	520	515
1053	524	534
1054	518	516
1055	515	514
1056	523	532
1057	517	535
1058	531	522
1059	537	519
1060	526	528
1061	524	523
1062	518	537
1063	514	526
1064	522	517
1065	537	524
1066	526	522
1067	524	522
1068	537	526
1069	560	561
1070	546	569
1071	554	551
1072	559	565
1073	548	539
1074	538	550
1075	557	545
1076	544	555
1077	543	563
1078	549	553
1079	541	567
1080	566	564
1081	540	556
1082	568	547
1083	542	552
1084	558	562
1085	560	546
1086	559	554
1087	569	561
1088	551	565
1089	545	539
1090	548	557
1091	538	544
1092	541	543
1093	555	550
1094	563	567
1095	540	568
1096	564	553
1097	549	566
1098	547	556
1099	552	562
1100	558	542
1101	561	546
1102	569	560
1103	565	554
1104	551	559
1105	539	557
1106	545	548
1107	550	544
1108	555	538
1109	564	549
1110	553	566
1111	563	541
1112	567	543
1113	552	558
1114	562	542
1115	547	540
1116	556	568
1117	548	538
1118	569	559
1119	565	560
1120	544	545
1121	541	553
1122	540	552
1123	566	567
1124	542	547
1125	569	548
1126	541	540
1127	566	547
1128	560	544
1129	548	540
1130	544	547
1131	540	547
1132	548	544
1133	578	589
1134	579	576
1135	590	588
1136	586	585
1137	571	580
1138	572	581
1139	577	587
1140	570	582
1141	574	573
1142	584	583
1143	575	591
1144	593	592
1145	585	589
1146	579	590
1147	578	586
1148	571	572
1149	588	576
1150	582	587
1151	581	580
1152	577	570
1153	583	573
1154	574	584
1155	591	592
1156	593	575
1157	576	590
1158	588	579
1159	585	578
1160	589	586
1161	580	572
1162	581	571
1163	582	577
1164	587	570
1165	573	584
1166	583	574
1167	591	593
1168	592	575
1169	579	585
1170	586	571
1171	577	573
1172	578	572
1173	590	593
1174	591	574
1175	580	576
1176	583	582
1177	586	577
1178	578	593
1179	580	583
1180	579	591
1181	577	593
1182	583	591
1183	577	591
1184	593	583
1185	615	603
1186	604	608
1187	617	612
1188	623	625
1189	594	616
1190	602	622
1191	610	613
1192	605	595
1193	611	601
1194	606	609
1195	620	600
1196	596	599
1197	621	598
1198	624	619
1199	614	607
1200	597	618
1201	625	608
1202	615	617
1203	612	603
1204	604	623
1205	622	595
1206	613	616
1207	605	602
1208	594	610
1209	609	600
1210	596	611
1211	601	599
1212	620	606
1213	598	618
1214	619	607
1215	597	621
1216	614	624
1217	603	617
1218	612	615
1219	608	623
1220	625	604
1221	595	602
1222	622	605
1223	613	594
1224	616	610
1225	599	611
1226	601	596
1227	600	606
1228	609	620
1229	607	624
1230	619	614
1231	598	597
1232	618	621
1233	612	623
1234	594	595
1235	605	613
1236	604	617
1237	609	601
1238	597	619
1239	611	620
1240	614	621
1241	601	597
1242	612	594
1243	611	614
1244	604	605
1245	594	601
1246	605	611
1247	601	611
1248	594	605
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
21776	20	Loïc	Rémy	2	1	1987	M
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
382	8	6	phase de pool	La Bombonera	204	204	196	196
1	13	7	phase de pool	Estadio Pocitos	5	6	7	6
2	13	7	phase de pool	Estadio Gran Parque Central	6	11	2	11
3	14	7	phase de pool	Estadio Gran Parque Central	9	13	4	13
4	14	7	phase de pool	Estadio Pocitos	11	10	9	10
5	15	7	phase de pool	Estadio Gran Parque Central	3	1	6	1
6	16	7	phase de pool	Estadio Gran Parque Central	2	5	7	5
7	17	7	phase de pool	Estadio Gran Parque Central	7	13	3	13
8	17	7	phase de pool	Estadio Gran Parque Central	6	11	8	11
9	18	7	phase de pool	Estadio Centenario	4	12	9	12
10	19	7	phase de pool	Estadio Centenario	9	5	6	5
11	19	7	phase de pool	Estadio Centenario	8	1	7	1
12	20	7	phase de pool	Estadio Centenario	1	4	3	4
13	20	7	phase de pool	Estadio Centenario	10	8	2	8
14	21	7	phase de pool	Estadio Centenario	3	12	10	12
15	22	7	phase de pool	Estadio Centenario	4	1	5	1
16	26	7	1/2	Estadio Centenario	4	1	11	1
17	27	7	1/2	Estadio Centenario	3	12	13	12
18	30	7	Finale	Estadio Centenario	4	12	1	12
19	27	5	1/8	Stadio Benito Mussolini	21	15	20	15
20	27	5	1/8	Stadio Littorio	4	18	25	18
21	27	5	1/8	Stadio Giovanni Berta	19	21	16	21
22	27	5	1/8	Stadio Giorgio Ascarelli	13	22	19	22
23	27	5	1/8	Stadio Nazionale PNF	20	23	29	23
24	27	5	1/8	Stadio Luigi Ferraris	15	26	17	26
25	27	5	1/8	Stadio Renato Dall'Ara	16	27	14	27
26	27	5	1/8	San Siro	18	28	24	28
27	31	5	1/4	Stadio Renato Dall'Ara	19	15	22	15
28	31	5	1/4	Stadio Benito Mussolini	14	18	28	18
29	31	5	1/4	San Siro	13	21	27	21
30	31	5	1/4	Stadio Giovanni Berta	12	23	26	\N
31	1	6	1/4	Stadio Giovanni Berta	20	23	26	23
32	3	6	1/2	Stadio Nazionale PNF	13	18	21	18
33	3	6	1/2	San Siro	18	23	15	23
34	7	6	FinaleConsolation	Stadio Giorgio Ascarelli	17	21	15	21
35	10	6	Finale	Stadio Nazionale PNF	18	23	18	23
36	4	6	1/8	Parc des Princes	4	44	36	\N
37	5	6	1/8	Stade du T.O.E.C.	26	32	42	\N
38	5	6	1/8	Stade Olympique de Colombes	28	35	30	35
39	5	6	1/8	Vélodrome Municipal	23	37	34	37
40	5	6	1/8	Stade Vélodrome	14	38	40	38
41	5	6	1/8	Stade de la Meinau	18	31	41	31
42	5	6	1/8	Stade Jules Deschaseaux	25	33	39	33
43	9	6	1/8	Stade du T.O.E.C.	15	32	42	32
44	9	6	1/8	Parc des Princes	18	44	36	44
45	12	6	1/4	Stade du Parc Lescure	27	31	33	\N
46	12	6	1/4	Stade Victor Boucquey	13	37	44	37
47	12	6	1/4	Stade Olympique de Colombes	12	38	35	38
48	12	6	1/4	Stade du Fort Carré	24	43	32	43
49	14	6	1/4	Stade du Parc Lescure	22	31	33	31
50	16	6	1/2	Parc des Princes	25	37	43	37
51	16	6	1/2	Stade Vélodrome	28	38	31	38
52	19	6	FinaleConsolation	Stade du Parc Lescure	4	31	43	31
53	19	6	Finale	Stade Olympique de Colombes	22	38	37	38
54	24	6	phase de pool	Estádio do Maracanã	39	46	50	46
55	25	6	phase de pool	Estádio Independência	32	57	54	57
56	25	6	phase de pool	Estádio do Maracanã	40	48	47	48
57	25	6	phase de pool	Estádio Vila Capanema	41	52	55	52
58	25	6	phase de pool	Estádio do Pacaembu	36	53	49	53
59	28	6	phase de pool	Estádio do Pacaembu	29	46	54	\N
60	28	6	phase de pool	Estádio dos Eucaliptos	35	57	50	57
61	29	6	phase de pool	Estádio do Maracanã	37	52	47	52
62	29	6	phase de pool	Estádio Independência	30	55	48	55
63	29	6	phase de pool	Estádio Vila Capanema	38	53	51	\N
64	1	7	phase de pool	Estádio do Maracanã	34	46	57	46
65	2	7	phase de pool	Estádio Ilha do Retiro	33	47	55	47
66	2	7	phase de pool	Estádio do Maracanã	32	52	48	52
67	2	7	phase de pool	Estádio do Pacaembu	31	49	51	49
68	2	7	phase de pool	Estádio Independência	39	56	45	56
69	2	7	phase de pool	Estádio dos Eucaliptos	18	54	50	54
70	9	7	phase de pool	Estádio do Maracanã	31	46	53	46
71	9	7	phase de pool	Estádio do Pacaembu	34	56	52	\N
72	13	7	phase de pool	Estádio do Maracanã	35	46	52	46
73	13	7	phase de pool	Estádio do Pacaembu	32	56	53	56
74	16	7	phase de pool	Estádio do Pacaembu	40	53	52	53
75	16	7	phase de pool	Estádio do Maracanã	39	56	46	56
76	16	6	phase de pool	Charmilles Stadium	53	60	66	60
77	16	6	phase de pool	Stade Olympique de la Pontaise	34	73	63	73
78	16	6	phase de pool	Hardturm Stadium	45	58	67	58
79	16	6	phase de pool	Wankdorf Stadium	31	71	61	71
80	17	6	phase de pool	Stade Olympique de la Pontaise	41	69	65	69
81	17	6	phase de pool	Hardturm Stadium	52	64	68	64
82	17	6	phase de pool	Wankdorf Stadium	43	72	70	72
83	17	6	phase de pool	St. Jakob Stadium	49	62	59	\N
84	19	6	phase de pool	St. Jakob Stadium	48	71	67	71
85	19	6	phase de pool	Stade Olympique de la Pontaise	44	60	73	\N
86	19	6	phase de pool	Hardturm Stadium	50	58	61	58
87	19	6	phase de pool	Charmilles Stadium	42	63	66	63
88	20	6	phase de pool	St. Jakob Stadium	46	64	72	64
89	20	6	phase de pool	Charmilles Stadium	47	70	68	70
90	20	6	phase de pool	Cornaredo Stadium	51	65	59	65
91	20	6	phase de pool	Wankdorf Stadium	54	62	69	62
92	23	6	phase de pool	Hardturm Stadium	52	72	70	72
93	23	6	phase de pool	St. Jakob Stadium	34	69	65	69
94	26	6	1/4	Stade Olympique de la Pontaise	44	58	69	58
95	26	6	1/4	St. Jakob Stadium	51	71	62	71
96	27	6	1/4	Wankdorf Stadium	31	64	60	64
97	27	6	1/4	Charmilles Stadium	54	72	73	72
98	30	6	1/2	Stade Olympique de la Pontaise	34	64	71	64
99	30	6	1/2	St. Jakob Stadium	48	72	58	72
100	3	7	FinaleConsolation	Hardturm Stadium	53	58	71	58
101	4	7	Finale	Wankdorf Stadium	46	72	64	72
102	8	6	phase de pool	Råsunda Stadium	65	86	81	86
103	8	6	phase de pool	Malmö Stadion	35	74	88	88
104	8	6	phase de pool	Örjans Vall	69	82	77	82
105	8	6	phase de pool	Idrottsparken	61	79	83	79
106	8	6	phase de pool	Arosvallen	53	89	84	\N
107	8	6	phase de pool	Jernvallen	58	80	87	\N
108	8	6	phase de pool	Rimnersvallen	62	76	75	76
109	8	6	phase de pool	Ullevi	54	85	78	\N
110	11	6	phase de pool	Örjans Vall	55	74	82	74
111	11	6	phase de pool	Olympia	31	88	77	\N
112	11	6	phase de pool	Idrottsparken	48	83	84	83
113	11	6	phase de pool	Arosvallen	34	89	79	89
114	11	6	phase de pool	Råsunda Stadium	64	81	87	\N
115	11	6	phase de pool	Ullevi	59	76	78	\N
116	11	6	phase de pool	Ryavallen	63	85	75	85
117	12	6	phase de pool	Råsunda Stadium	67	86	80	86
118	15	6	phase de pool	Råsunda Stadium	70	86	87	\N
119	15	6	phase de pool	Olympia	31	77	74	77
120	15	6	phase de pool	Malmö Stadion	57	88	82	\N
121	15	6	phase de pool	Eyravallen	68	79	84	79
122	15	6	phase de pool	Tunavallen	66	83	89	\N
123	15	6	phase de pool	Jernvallen	60	80	81	80
124	15	6	phase de pool	Ullevi	62	76	85	76
125	15	6	phase de pool	Ryavallen	56	78	75	\N
126	17	6	phase de pool	Malmö Stadion	62	82	77	82
127	17	6	phase de pool	Råsunda Stadium	65	87	80	87
128	17	6	phase de pool	Ullevi	59	85	78	85
129	19	6	1/4	Ullevi	69	76	87	76
130	19	6	1/4	Idrottsparken	61	79	82	79
131	19	6	1/4	Råsunda Stadium	35	86	85	86
132	19	6	1/4	Malmö Stadion	53	88	89	88
133	24	6	1/2	Råsunda Stadium	34	76	79	76
134	24	6	1/2	Ullevi	54	86	88	86
135	28	6	FinaleConsolation	Ullevi	68	79	88	79
136	29	6	Finale	Råsunda Stadium	62	76	86	76
137	30	5	phase de pool	Estadio Carlos Dittborn	76	103	94	103
138	30	5	phase de pool	Estadio Nacional	71	93	102	93
139	30	5	phase de pool	Estadio Sausalito	75	91	99	91
140	30	5	phase de pool	Estadio El Teniente	61	90	92	90
141	31	5	phase de pool	Estadio Carlos Dittborn	59	100	105	100
142	31	5	phase de pool	Estadio Nacional	74	104	98	\N
143	31	5	phase de pool	Estadio Sausalito	51	95	101	95
144	31	5	phase de pool	Estadio El Teniente	79	97	96	97
145	2	6	phase de pool	Estadio Carlos Dittborn	78	105	103	105
146	2	6	phase de pool	Estadio Nacional	71	93	98	93
147	2	6	phase de pool	Estadio Sausalito	82	91	95	\N
148	2	6	phase de pool	Estadio El Teniente	65	96	90	96
149	3	6	phase de pool	Estadio Carlos Dittborn	77	100	94	\N
150	3	6	phase de pool	Estadio Nacional	79	104	102	104
151	3	6	phase de pool	Estadio Sausalito	83	101	99	101
152	3	6	phase de pool	Estadio El Teniente	61	97	92	97
153	6	6	phase de pool	Estadio Carlos Dittborn	80	100	103	100
154	6	6	phase de pool	Estadio Nacional	74	104	93	104
155	6	6	phase de pool	Estadio Sausalito	73	91	101	91
156	6	6	phase de pool	Estadio El Teniente	84	97	90	\N
157	7	6	phase de pool	Estadio Carlos Dittborn	81	105	94	105
158	7	6	phase de pool	Estadio Nacional	65	98	102	98
159	7	6	phase de pool	Estadio Sausalito	75	99	95	99
160	7	6	phase de pool	Estadio El Teniente	72	96	92	\N
161	10	6	1/4	Estadio Sausalito	82	91	96	91
162	10	6	1/4	Estadio Carlos Dittborn	79	93	100	93
163	10	6	1/4	Estadio El Teniente	65	95	97	95
164	10	6	1/4	Estadio Nacional	84	105	104	105
165	13	6	1/2	Estadio Nacional	84	91	93	91
166	13	6	1/2	Estadio Sausalito	75	95	105	95
167	16	6	FinaleConsolation	Estadio Nacional	61	93	105	93
168	17	6	Finale	Estadio Nacional	65	91	95	91
169	11	7	phase de pool	Wembley Stadium	54	110	120	\N
170	12	7	phase de pool	Hillsborough Stadium	98	121	119	121
171	12	7	phase de pool	Goodison Park	100	107	108	107
172	12	7	phase de pool	Ayresome Park	61	117	115	117
173	13	7	phase de pool	Wembley Stadium	86	111	114	\N
174	13	7	phase de pool	Villa Park	99	106	118	106
175	13	7	phase de pool	Old Trafford	88	116	112	116
176	13	7	phase de pool	Roker Park	75	113	109	113
177	15	7	phase de pool	White City Stadium	78	120	111	120
178	15	7	phase de pool	Hillsborough Stadium	87	118	119	118
179	15	7	phase de pool	Goodison Park	89	112	107	112
180	15	7	phase de pool	Ayresome Park	92	109	115	\N
181	16	7	phase de pool	Villa Park	101	106	121	\N
182	16	7	phase de pool	Old Trafford	58	116	108	116
183	16	7	phase de pool	Roker Park	93	117	113	117
184	16	7	phase de pool	Wembley Stadium	94	110	114	110
185	19	7	phase de pool	Wembley Stadium	95	114	120	\N
186	19	7	phase de pool	Hillsborough Stadium	57	106	119	106
187	19	7	phase de pool	Goodison Park	97	116	107	116
188	19	7	phase de pool	Ayresome Park	82	115	113	115
189	20	7	phase de pool	Wembley Stadium	84	110	111	110
190	20	7	phase de pool	Villa Park	96	121	118	121
191	20	7	phase de pool	Old Trafford	91	112	108	112
192	20	7	phase de pool	Roker Park	85	117	109	117
193	23	7	1/4	Wembley Stadium	93	110	106	110
194	23	7	1/4	Goodison Park	86	116	115	116
195	23	7	1/4	Roker Park	61	117	112	117
196	23	7	1/4	Hillsborough Stadium	90	121	120	121
197	25	7	1/2	Goodison Park	94	121	117	121
198	26	7	1/2	Wembley Stadium	82	110	116	110
199	28	7	FinaleConsolation	Wembley Stadium	89	116	117	116
200	30	7	Finale	Wembley Stadium	75	110	121	110
201	31	5	phase de pool	Estadio Azteca	100	130	134	\N
202	2	6	phase de pool	Estadio Cuauhtémoc	74	136	128	136
203	2	6	phase de pool	Estadio Jalisco	109	127	133	127
204	2	6	phase de pool	Estadio Nou Camp	116	132	124	132
205	3	6	phase de pool	Estadio Azteca	114	122	126	122
206	3	6	phase de pool	La Bombonera	119	129	135	129
207	3	6	phase de pool	Estadio Jalisco	103	123	125	123
208	3	6	phase de pool	Estadio Nou Camp	120	137	131	137
209	6	6	phase de pool	Estadio Azteca	117	134	122	134
210	6	6	phase de pool	Estadio Cuauhtémoc	105	136	129	\N
211	6	6	phase de pool	Estadio Jalisco	104	133	125	133
212	6	6	phase de pool	Estadio Nou Camp	87	132	131	132
213	7	6	phase de pool	Estadio Azteca	92	130	126	130
214	7	6	phase de pool	La Bombonera	118	135	128	\N
215	7	6	phase de pool	Estadio Jalisco	107	123	127	123
216	7	6	phase de pool	Estadio Nou Camp	113	137	124	137
217	10	6	phase de pool	Estadio Azteca	106	134	126	134
218	10	6	phase de pool	Estadio Cuauhtémoc	108	135	136	135
219	10	6	phase de pool	Estadio Jalisco	111	123	133	123
220	10	6	phase de pool	Estadio Nou Camp	102	137	132	137
221	11	6	phase de pool	Estadio Azteca	112	130	122	130
222	11	6	phase de pool	La Bombonera	121	129	128	\N
223	11	6	phase de pool	Estadio Jalisco	110	127	125	127
224	11	6	phase de pool	Estadio Nou Camp	115	124	131	\N
225	14	6	1/4	Estadio Jalisco	109	123	132	123
226	14	6	1/4	La Bombonera	117	129	130	129
227	14	6	1/4	Estadio Azteca	120	134	136	136
228	14	6	1/4	Estadio Nou Camp	112	137	127	137
229	17	6	1/2	Estadio Jalisco	113	123	136	123
230	17	6	1/2	Estadio Azteca	84	129	137	129
231	20	6	FinaleConsolation	Estadio Azteca	116	137	136	137
232	21	6	Finale	Estadio Azteca	105	123	129	123
233	13	6	phase de pool	Waldstadion	117	140	152	\N
234	14	6	phase de pool	Olympiastadion	123	151	142	151
235	14	6	phase de pool	Volksparkstadion	131	143	139	143
236	14	6	phase de pool	Westfalenstadion	138	153	148	148
237	15	6	phase de pool	Rheinstadion	134	149	141	\N
238	15	6	phase de pool	Niedersachsenstadion	133	150	146	146
239	15	6	phase de pool	Olympiastadion	129	145	144	145
240	15	6	phase de pool	Neckarstadion	140	147	138	147
241	18	6	phase de pool	Volksparkstadion	130	139	151	151
242	18	6	phase de pool	Olympiastadion	122	142	143	\N
243	18	6	phase de pool	Waldstadion	141	148	140	\N
244	18	6	phase de pool	Parkstadion	125	152	153	152
245	19	6	phase de pool	Niedersachsenstadion	119	141	150	\N
246	19	6	phase de pool	Westfalenstadion	143	146	149	\N
247	19	6	phase de pool	Neckarstadion	127	138	145	\N
248	19	6	phase de pool	Olympiastadion	139	144	147	147
249	22	6	phase de pool	Olympiastadion	132	139	142	\N
250	22	6	phase de pool	Waldstadion	126	148	152	\N
251	22	6	phase de pool	Parkstadion	136	153	140	140
252	22	6	phase de pool	Volksparkstadion	103	143	151	143
253	23	6	phase de pool	Westfalenstadion	124	141	146	146
254	23	6	phase de pool	Rheinstadion	128	149	150	149
255	23	6	phase de pool	Olympiastadion	137	138	144	138
256	23	6	phase de pool	Neckarstadion	142	147	145	147
257	26	6	phase de pool	Rheinstadion	96	152	151	151
258	26	6	phase de pool	Niedersachsenstadion	140	140	143	140
259	26	6	phase de pool	Parkstadion	74	146	138	146
260	26	6	phase de pool	Neckarstadion	103	149	147	147
261	30	6	phase de pool	Niedersachsenstadion	109	138	140	140
262	30	6	phase de pool	Parkstadion	117	143	146	146
263	30	6	phase de pool	Waldstadion	105	147	152	147
264	30	6	phase de pool	Rheinstadion	127	151	149	151
265	3	7	phase de pool	Waldstadion	128	147	151	151
266	3	7	phase de pool	Parkstadion	119	138	143	\N
267	3	7	phase de pool	Westfalenstadion	100	146	140	146
268	3	7	phase de pool	Rheinstadion	135	149	152	149
269	6	7	FinaleConsolation	Olympiastadion	122	140	147	147
270	7	7	Finale	Olympiastadion	119	146	151	151
271	1	6	phase de pool	Estadio Monumental	112	169	164	\N
272	2	6	phase de pool	Estadio José María Minella	136	160	157	160
273	2	6	phase de pool	Estadio Gigante de Arroyito	152	168	161	168
274	2	6	phase de pool	Estadio Monumental	150	154	158	154
275	3	6	phase de pool	Estadio José Amalfitani	133	155	166	155
276	3	6	phase de pool	Estadio José María Minella	140	156	167	\N
277	3	6	phase de pool	Estadio Ciudad de Mendoza	126	162	159	162
278	3	6	phase de pool	Estadio Chateau Carreras	149	163	165	163
279	6	6	phase de pool	Estadio José María Minella	103	160	158	160
280	6	6	phase de pool	Estadio Gigante de Arroyito	156	164	168	164
281	6	6	phase de pool	Estadio Chateau Carreras	145	169	161	169
282	6	6	phase de pool	Estadio Monumental	148	154	157	154
283	7	6	phase de pool	Estadio José Amalfitani	147	155	167	155
284	7	6	phase de pool	Estadio José María Minella	151	156	166	\N
285	7	6	phase de pool	Estadio Ciudad de Mendoza	158	162	163	\N
286	7	6	phase de pool	Estadio Chateau Carreras	131	165	159	\N
287	10	6	phase de pool	Estadio José María Minella	146	157	158	157
288	10	6	phase de pool	Estadio Gigante de Arroyito	132	164	161	164
289	10	6	phase de pool	Estadio Chateau Carreras	153	169	168	\N
290	10	6	phase de pool	Estadio Monumental	107	154	160	160
291	11	6	phase de pool	Estadio José María Minella	161	156	155	156
292	11	6	phase de pool	Estadio José Amalfitani	144	166	167	166
293	11	6	phase de pool	Estadio Chateau Carreras	154	163	159	163
294	11	6	phase de pool	Estadio Ciudad de Mendoza	128	165	162	165
295	14	6	phase de pool	Estadio Chateau Carreras	152	155	162	162
296	14	6	phase de pool	Estadio Monumental	155	160	169	\N
297	14	6	phase de pool	Estadio Ciudad de Mendoza	136	156	163	156
298	14	6	phase de pool	Estadio Gigante de Arroyito	149	154	164	154
299	18	6	phase de pool	Estadio Ciudad de Mendoza	157	163	164	164
300	18	6	phase de pool	Estadio Monumental	159	160	155	160
301	18	6	phase de pool	Estadio Chateau Carreras	103	162	169	\N
302	18	6	phase de pool	Estadio Gigante de Arroyito	133	154	156	\N
303	21	6	phase de pool	Estadio Chateau Carreras	107	155	169	155
304	21	6	phase de pool	Estadio Monumental	156	160	162	162
305	21	6	phase de pool	Estadio Ciudad de Mendoza	160	156	164	156
306	21	6	phase de pool	Estadio Gigante de Arroyito	161	154	163	154
307	24	6	FinaleConsolation	Estadio Monumental	107	156	160	156
308	25	6	Finale	Estadio Monumental	151	154	162	154
309	13	6	phase de pool	Camp Nou	170	171	173	173
310	14	6	phase de pool	Balaídos	190	183	188	\N
311	14	6	phase de pool	Estadio Ramón Sánchez Pizjuán	179	174	190	174
312	15	6	phase de pool	Estadio Riazor	193	187	175	\N
313	15	6	phase de pool	Nuevo Estadio	162	182	178	182
314	15	6	phase de pool	Estadio La Rosaleda	187	189	185	189
315	16	6	phase de pool	Estadio El Molinón	177	192	170	170
316	16	6	phase de pool	Estadio San Mamés	150	179	180	179
317	16	6	phase de pool	Estadio Luis Casanova	176	191	181	\N
318	17	6	phase de pool	Estadio Carlos Tartiere	166	176	172	172
319	17	6	phase de pool	Estadio José Zorrilla	172	177	184	\N
320	17	6	phase de pool	Estadio La Romareda	174	193	186	\N
321	18	6	phase de pool	Balaídos	173	183	187	\N
322	18	6	phase de pool	Estadio José Rico Pérez	178	171	182	171
323	18	6	phase de pool	Estadio Benito Villamarín	185	174	189	174
324	19	6	phase de pool	Estadio Riazor	186	188	175	\N
325	19	6	phase de pool	Nuevo Estadio	183	173	178	173
326	19	6	phase de pool	Estadio La Rosaleda	163	190	185	190
327	20	6	phase de pool	Estadio El Molinón	175	192	176	192
328	20	6	phase de pool	Estadio San Mamés	147	179	177	179
329	20	6	phase de pool	Estadio Luis Casanova	180	191	193	191
330	21	6	phase de pool	Estadio Carlos Tartiere	124	170	172	172
331	21	6	phase de pool	Estadio José Zorrilla	188	180	184	180
332	21	6	phase de pool	Estadio La Romareda	169	181	186	\N
333	22	6	phase de pool	Estadio Riazor	191	188	187	188
334	22	6	phase de pool	Nuevo Estadio	192	173	182	\N
335	22	6	phase de pool	Estadio La Rosaleda	136	190	189	\N
336	23	6	phase de pool	Balaídos	171	183	175	\N
337	23	6	phase de pool	Estadio José Rico Pérez	165	171	178	171
338	23	6	phase de pool	Estadio Benito Villamarín	181	174	185	174
339	24	6	phase de pool	Estadio Carlos Tartiere	182	170	176	170
340	24	6	phase de pool	Estadio José Zorrilla	167	180	177	\N
341	24	6	phase de pool	Estadio La Romareda	168	181	193	193
342	25	6	phase de pool	Estadio El Molinón	189	192	172	192
343	25	6	phase de pool	Estadio San Mamés	164	179	184	179
344	25	6	phase de pool	Estadio Luis Casanova	184	191	186	186
345	28	6	phase de pool	Vicente Calderón	133	172	180	180
346	28	6	phase de pool	Camp Nou	185	188	173	188
347	29	6	phase de pool	Estadi de Sarrià	136	183	171	183
348	29	6	phase de pool	Estadio Santiago Bernabéu	146	192	179	\N
349	1	7	phase de pool	Vicente Calderón	158	172	186	\N
350	1	7	phase de pool	Camp Nou	190	173	190	190
351	2	7	phase de pool	Estadi de Sarrià	191	171	174	174
352	2	7	phase de pool	Estadio Santiago Bernabéu	167	192	191	192
353	4	7	phase de pool	Vicente Calderón	154	180	186	180
354	4	7	phase de pool	Camp Nou	189	190	188	\N
355	5	7	phase de pool	Estadi de Sarrià	107	183	174	183
356	5	7	phase de pool	Estadio Santiago Bernabéu	186	191	179	\N
357	8	7	1/2	Camp Nou	166	188	183	183
358	8	7	1/2	Estadio Ramón Sánchez Pizjuán	147	192	180	192
359	10	7	FinaleConsolation	Estadio José Rico Pérez	150	188	180	188
360	11	7	Finale	Estadio Santiago Bernabéu	146	183	192	183
361	31	5	phase de pool	Estadio Azteca	174	198	205	\N
362	1	6	phase de pool	Estadio Jalisco	198	215	197	197
363	1	6	phase de pool	Estadio Nou Camp	218	199	202	202
364	2	6	phase de pool	Estadio Olímpico Universitario	217	195	213	195
365	2	6	phase de pool	Estadio Sergio León Chavez	194	214	203	214
366	2	6	phase de pool	Estadio Universitario	211	207	210	\N
367	3	6	phase de pool	Estadio Azteca	205	196	206	206
368	3	6	phase de pool	Estadio Tres de Marzo	201	194	208	\N
369	3	6	phase de pool	Estadio Tecnológico	216	211	201	211
370	4	6	phase de pool	La Bombonera	214	209	204	209
371	4	6	phase de pool	Estadio La Corregidora	170	216	217	\N
372	4	6	phase de pool	Estadio Neza 86	212	212	200	200
373	5	6	phase de pool	Estadio Cuauhtémoc	208	205	195	\N
374	5	6	phase de pool	Estadio Nou Camp	197	202	214	\N
375	5	6	phase de pool	Estadio Olímpico Universitario	195	213	198	\N
376	6	6	phase de pool	Estadio Sergio León Chavez	196	203	199	203
377	6	6	phase de pool	Estadio Jalisco	182	197	194	197
378	6	6	phase de pool	Estadio Tecnológico	206	201	207	\N
379	7	6	phase de pool	Estadio Azteca	202	206	209	\N
380	7	6	phase de pool	Estadio Tres de Marzo	200	208	215	215
381	7	6	phase de pool	Estadio Universitario	199	210	211	210
383	8	6	phase de pool	Estadio La Corregidora	207	217	212	217
384	8	6	phase de pool	Estadio Neza 86	210	200	216	200
385	9	6	phase de pool	Estadio Nou Camp	219	203	202	202
386	9	6	phase de pool	Estadio Sergio León Chavez	222	214	199	214
387	10	6	phase de pool	Estadio Olímpico Universitario	223	195	198	195
388	10	6	phase de pool	Estadio Cuauhtémoc	187	213	205	205
389	11	6	phase de pool	Estadio Azteca	213	204	206	206
390	11	6	phase de pool	La Bombonera	171	209	196	\N
391	11	6	phase de pool	Estadio Universitario	203	201	210	201
392	11	6	phase de pool	Estadio Tres de Marzo	220	211	207	207
393	12	6	phase de pool	Estadio Tecnológico	221	194	215	215
394	12	6	phase de pool	Estadio Jalisco	209	208	197	197
395	13	6	phase de pool	Estadio La Corregidora	186	200	217	200
396	13	6	phase de pool	Estadio Neza 86	215	212	216	\N
397	15	6	1/8	Estadio Azteca	197	206	198	206
398	15	6	1/8	Estadio Nou Camp	174	214	196	196
399	16	6	1/8	Estadio Jalisco	216	197	210	197
400	16	6	1/8	Estadio Cuauhtémoc	194	195	216	195
401	17	6	1/8	Estadio Olímpico Universitario	205	205	202	202
402	17	6	1/8	Estadio Universitario	213	207	217	217
403	18	6	1/8	Estadio Azteca	196	201	209	201
404	18	6	1/8	Estadio La Corregidora	208	200	215	215
405	21	6	1/4	Estadio Jalisco	207	197	202	202
406	21	6	1/4	Estadio Universitario	204	217	206	217
407	22	6	1/4	Estadio Azteca	199	195	201	195
408	22	6	1/4	Estadio Cuauhtémoc	209	215	196	196
409	25	6	1/2	Estadio Jalisco	194	202	217	217
410	25	6	1/2	Estadio Azteca	210	195	196	195
411	28	6	FinaleConsolation	Estadio Cuauhtémoc	202	196	202	202
412	29	6	Finale	Estadio Azteca	197	195	217	195
413	8	6	phase de pool	San Siro	190	218	222	222
414	9	6	phase de pool	Stadio San Nicola	166	234	231	231
415	9	6	phase de pool	Stadio Renato Dall'Ara	202	237	223	223
416	9	6	phase de pool	Stadio Olimpico	239	228	219	228
417	10	6	phase de pool	Stadio Comunale	233	238	225	225
418	10	6	phase de pool	Stadio delle Alpi	228	221	236	221
419	10	6	phase de pool	San Siro	232	240	241	240
420	11	6	phase de pool	Stadio Luigi Ferraris	229	224	232	224
421	11	6	phase de pool	Stadio Sant'Elia	234	227	230	\N
422	12	6	phase de pool	Stadio Marc'Antonio Bentegodi	231	220	233	220
423	12	6	phase de pool	Stadio La Favorita	236	229	226	\N
424	13	6	phase de pool	Stadio Friuli	227	239	235	\N
425	13	6	phase de pool	Stadio San Paolo	174	218	234	218
426	14	6	phase de pool	Stadio San Nicola	218	222	231	222
427	14	6	phase de pool	Stadio Renato Dall'Ara	194	241	223	241
428	14	6	phase de pool	Stadio Olimpico	224	228	238	228
429	15	6	phase de pool	Stadio Comunale	235	219	225	225
430	15	6	phase de pool	San Siro	237	240	237	240
431	16	6	phase de pool	Stadio delle Alpi	226	221	224	221
432	16	6	phase de pool	Stadio Luigi Ferraris	230	236	232	232
433	16	6	phase de pool	Stadio Sant'Elia	213	227	229	\N
434	17	6	phase de pool	Stadio La Favorita	238	230	226	\N
435	17	6	phase de pool	Stadio Marc'Antonio Bentegodi	209	220	239	220
436	17	6	phase de pool	Stadio Friuli	225	233	235	235
437	18	6	phase de pool	Stadio San Paolo	219	218	231	\N
438	18	6	phase de pool	Stadio San Nicola	239	222	234	234
439	19	6	phase de pool	San Siro	220	240	223	\N
440	19	6	phase de pool	Stadio Renato Dall'Ara	221	241	237	241
441	19	6	phase de pool	Stadio Comunale	196	219	238	219
442	19	6	phase de pool	Stadio Olimpico	215	228	225	228
443	20	6	phase de pool	Stadio delle Alpi	227	221	232	221
444	20	6	phase de pool	Stadio Luigi Ferraris	213	236	224	224
445	21	6	phase de pool	Stadio Marc'Antonio Bentegodi	229	220	235	235
446	21	6	phase de pool	Stadio Friuli	228	233	239	239
447	21	6	phase de pool	Stadio Sant'Elia	233	227	226	227
448	21	6	phase de pool	Stadio La Favorita	190	230	229	\N
449	23	6	1/8	Stadio San Paolo	228	222	223	222
450	23	6	1/8	Stadio San Nicola	209	225	224	225
451	24	6	1/8	Stadio delle Alpi	215	221	218	218
452	24	6	1/8	San Siro	229	240	229	240
453	25	6	1/8	Stadio Luigi Ferraris	239	230	231	230
454	25	6	1/8	Stadio Olimpico	202	228	239	228
455	26	6	1/8	Stadio Marc'Antonio Bentegodi	234	235	241	241
456	26	6	1/8	Stadio Renato Dall'Ara	232	227	220	227
457	30	6	1/4	Stadio Comunale	233	218	241	218
458	30	6	1/4	Stadio Olimpico	219	230	228	228
459	1	7	1/4	San Siro	227	225	240	240
460	1	7	1/4	Stadio San Paolo	224	222	227	227
461	3	7	1/2	Stadio San Paolo	190	218	228	218
462	4	7	1/2	Stadio delle Alpi	239	240	227	240
463	7	7	FinaleConsolation	Stadio San Nicola	215	228	227	228
464	8	7	Finale	Stadio Olimpico	224	240	218	240
465	16	11	phase de pool	Tainhe Stadium	241	243	251	243
466	17	11	phase de pool	Jiangmen Stadium	245	246	250	246
467	17	11	phase de pool	Tainhe Stadium	249	245	249	245
468	17	11	phase de pool	New Plaza Stadium	242	248	242	242
469	17	11	phase de pool	Ying Tung Stadium	247	252	253	253
470	17	11	phase de pool	Jiangmen Stadium	240	244	247	247
471	19	11	phase de pool	Gaungdong Provincial Stadium	241	251	249	251
472	19	11	phase de pool	Zhongshan Stadium	243	247	250	247
473	19	11	phase de pool	Gaungdong Provincial Stadium	244	243	245	\N
474	19	11	phase de pool	Ying Tung Stadium	250	242	253	253
475	19	11	phase de pool	New Plaza Stadium	246	248	252	252
476	19	11	phase de pool	Zhongshan Stadium	240	244	246	246
477	21	11	phase de pool	Ying Tung Stadium	242	242	252	252
478	21	11	phase de pool	New Plaza Stadium	247	248	253	253
479	21	11	phase de pool	New Plaza Stadium	246	243	249	243
480	21	11	phase de pool	New Plaza Stadium	250	251	245	251
481	21	11	phase de pool	Jiangmen Stadium	245	244	250	244
482	21	11	phase de pool	Zhongshan Stadium	243	247	246	246
483	24	11	1/4	Zhongshan Stadium	244	245	246	246
484	24	11	1/4	Tianhe Stadium	247	243	252	252
485	24	11	1/4	Jiangmen Stadium	245	251	247	251
486	24	11	1/4	New Plaza Stadium	249	253	244	253
487	27	11	1/2	Ying Tung Stadium	243	252	251	251
488	27	11	1/2	Guangdong Provincial Stadium	241	246	253	253
489	29	11	FinaleConsolation	Gaungdong Provincial Stadium	248	252	246	252
490	30	11	Finale	Tianhe Stadium	250	251	253	253
491	17	6	phase de pool	Soldier Field	254	261	256	261
492	17	6	phase de pool	Cotton Bowl	232	274	273	\N
493	18	6	phase de pool	Pontiac Silverdome	261	277	276	\N
494	18	6	phase de pool	Giants Stadium	269	263	269	269
495	18	6	phase de pool	Rose Bowl	196	260	270	270
496	19	6	phase de pool	Citrus Bowl	268	255	265	255
497	19	6	phase de pool	RFK Stadium	266	268	264	268
498	19	6	phase de pool	Rose Bowl	267	259	275	\N
499	20	6	phase de pool	Stanford Stadium	262	257	271	257
500	20	6	phase de pool	RFK Stadium	257	266	272	266
501	21	6	phase de pool	Foxboro Stadium	251	254	262	254
502	21	6	phase de pool	Soldier Field	256	261	274	\N
503	21	6	phase de pool	Cotton Bowl	252	267	258	267
504	22	6	phase de pool	Pontiac Silverdome	226	270	276	276
505	22	6	phase de pool	Rose Bowl	253	277	260	277
506	23	6	phase de pool	Giants Stadium	260	263	268	263
507	23	6	phase de pool	Foxboro Stadium	264	273	256	\N
508	24	6	phase de pool	Citrus Bowl	233	264	269	264
509	24	6	phase de pool	Stanford Stadium	254	257	259	257
510	24	6	phase de pool	Pontiac Silverdome	215	275	271	275
511	25	6	phase de pool	Citrus Bowl	263	255	266	255
512	25	6	phase de pool	Giants Stadium	258	272	265	272
513	25	6	phase de pool	Foxboro Stadium	259	254	267	254
514	26	6	phase de pool	Soldier Field	255	258	262	258
515	26	6	phase de pool	Stanford Stadium	232	276	260	260
516	26	6	phase de pool	Rose Bowl	269	277	270	270
517	27	6	phase de pool	Soldier Field	252	256	274	274
518	27	6	phase de pool	Cotton Bowl	215	261	273	261
519	28	6	phase de pool	RFK Stadium	261	263	264	\N
520	28	6	phase de pool	Giants Stadium	268	269	268	\N
521	28	6	phase de pool	Stanford Stadium	196	271	259	271
522	28	6	phase de pool	Pontiac Silverdome	266	257	275	\N
523	29	6	phase de pool	RFK Stadium	260	255	272	272
524	29	6	phase de pool	Citrus Bowl	267	265	266	266
525	30	6	phase de pool	Cotton Bowl	226	254	258	258
526	30	6	phase de pool	Foxboro Stadium	264	262	267	267
527	2	7	1/8	Soldier Field	233	261	255	261
528	2	7	1/8	RFK Stadium	269	274	276	274
529	3	7	1/8	Cotton Bowl	263	272	275	275
530	3	7	1/8	Rose Bowl	265	270	254	270
531	4	7	1/8	Citrus Bowl	232	266	269	266
532	4	7	1/8	Stanford Stadium	215	257	277	257
533	5	7	1/8	Foxboro Stadium	254	267	263	263
534	5	7	1/8	Giants Stadium	196	264	258	258
535	9	7	1/4	Foxboro Stadium	266	263	274	263
536	9	7	1/4	Cotton Bowl	252	266	257	257
537	10	7	1/4	Giants Stadium	268	258	261	258
538	10	7	1/4	Stanford Stadium	258	270	275	275
539	13	7	1/2	Giants Stadium	215	258	263	263
540	13	7	1/2	Rose Bowl	268	275	257	257
541	16	7	FinaleConsolation	Rose Bowl	255	275	258	275
542	17	7	Finale	Rose Bowl	266	257	263	257
543	5	6	phase de pool	Tingvalla IP	277	284	285	284
544	5	6	phase de pool	Olympia	272	288	279	279
545	6	6	phase de pool	Olympia	278	283	280	283
546	6	6	phase de pool	Tingvalla IP	274	287	286	287
547	6	6	phase de pool	Arosvallen	280	282	278	282
548	6	6	phase de pool	Strömvallen	276	289	281	\N
549	7	6	phase de pool	Tingvalla IP	275	279	285	285
550	7	6	phase de pool	Olympia	270	288	284	288
551	8	6	phase de pool	Olympia	281	286	280	\N
552	8	6	phase de pool	Tingvalla IP	273	287	283	287
553	8	6	phase de pool	Arosvallen	279	281	278	281
554	8	6	phase de pool	Strömvallen	271	289	282	289
555	9	6	phase de pool	Tingvalla IP	274	279	284	284
556	9	6	phase de pool	Arosvallen	277	288	285	288
557	10	6	phase de pool	Tingvalla IP	276	286	283	283
558	10	6	phase de pool	Strömvallen	279	287	280	287
559	10	6	phase de pool	Arosvallen	273	281	282	281
560	10	6	phase de pool	Olympia	281	289	278	289
561	13	6	1/4	Strömvallen	273	285	289	289
562	13	6	1/4	Tingvalla IP	281	287	282	287
563	13	6	1/4	Arosvallen	280	284	283	284
564	13	6	1/4	Olympia	272	288	281	281
565	15	6	1/2	Arosvallen	274	289	287	287
566	15	6	1/2	Olympia	277	284	281	284
567	17	6	FinaleConsolation	Strömvallen	272	281	289	289
568	18	6	Finale	Råsunda Stadium	276	284	287	287
569	10	6	phase de pool	Stade de France	292	293	315	293
570	10	6	phase de pool	Stade de la Mosson	281	308	311	\N
571	11	6	phase de pool	Stade du Parc Lescure	287	304	296	\N
572	11	6	phase de pool	Stade de Toulouse	293	295	291	\N
573	12	6	phase de pool	Stade de la Mosson	302	312	294	\N
574	12	6	phase de pool	Stade Félix-Bollaert	288	314	299	299
575	12	6	phase de pool	Stade Vélodrome	304	301	316	301
576	13	6	phase de pool	Stade de la Beaujoire	283	318	310	310
577	13	6	phase de pool	Stade de Gerland	286	317	307	307
578	13	6	phase de pool	Stade de France	289	309	292	\N
579	14	6	phase de pool	Stade de Toulouse	269	290	306	290
580	14	6	phase de pool	Stade Geoffroy-Guichard	267	321	303	321
581	14	6	phase de pool	Stade Félix-Bollaert	298	305	298	298
582	15	6	phase de pool	Stade Vélodrome	300	300	319	300
583	15	6	phase de pool	Stade de Gerland	262	313	297	313
584	15	6	phase de pool	Parc des Princes	285	302	320	302
585	16	6	phase de pool	Stade du Parc Lescure	306	315	311	\N
586	16	6	phase de pool	Stade de la Beaujoire	65	293	308	293
587	17	6	phase de pool	Stade Geoffroy-Guichard	282	296	291	\N
588	17	6	phase de pool	Stade de la Mosson	295	304	295	304
589	18	6	phase de pool	Stade de Toulouse	247	316	299	\N
590	18	6	phase de pool	Stade de France	254	301	314	301
591	19	6	phase de pool	Parc des Princes	305	310	294	310
592	19	6	phase de pool	Stade Geoffroy-Guichard	296	318	312	\N
593	20	6	phase de pool	Stade de la Beaujoire	303	306	298	298
594	20	6	phase de pool	Stade du Parc Lescure	290	292	307	\N
595	20	6	phase de pool	Stade Vélodrome	307	309	317	309
596	21	6	phase de pool	Stade Félix-Bollaert	299	302	321	\N
597	21	6	phase de pool	Parc des Princes	301	290	305	290
598	21	6	phase de pool	Stade de Gerland	297	320	303	303
599	22	6	phase de pool	Stade de la Mosson	294	297	319	297
600	22	6	phase de pool	Stade de Toulouse	284	313	300	313
601	23	6	phase de pool	Stade de la Beaujoire	306	296	295	\N
602	23	6	phase de pool	Stade de France	291	304	291	304
603	23	6	phase de pool	Stade Vélodrome	283	293	311	311
604	23	6	phase de pool	Stade Geoffroy-Guichard	255	315	308	308
605	24	6	phase de pool	Stade de Gerland	289	301	299	301
606	24	6	phase de pool	Stade du Parc Lescure	305	316	314	\N
607	24	6	phase de pool	Stade de Toulouse	281	310	312	312
608	24	6	phase de pool	Stade Félix-Bollaert	269	318	294	318
609	25	6	phase de pool	Parc des Princes	304	292	317	\N
610	25	6	phase de pool	Stade Geoffroy-Guichard	302	309	307	\N
611	25	6	phase de pool	Stade de la Mosson	293	302	303	302
612	25	6	phase de pool	Stade de la Beaujoire	282	320	321	321
613	26	6	phase de pool	Stade du Parc Lescure	285	290	298	290
614	26	6	phase de pool	Stade de Gerland	286	306	305	305
615	26	6	phase de pool	Stade Félix-Bollaert	254	297	300	300
616	26	6	phase de pool	Stade de France	295	313	319	\N
617	27	6	1/8	Stade Vélodrome	294	304	311	304
618	27	6	1/8	Parc des Princes	284	293	296	293
619	28	6	1/8	Stade Félix-Bollaert	255	301	312	301
620	28	6	1/8	Stade de France	297	310	299	299
621	29	6	1/8	Stade de la Mosson	298	302	307	302
622	29	6	1/8	Stade de Toulouse	292	309	321	309
623	30	6	1/8	Stade du Parc Lescure	288	313	298	298
624	30	6	1/8	Stade Geoffroy-Guichard	299	290	300	290
625	3	7	1/4	Stade de France	290	304	301	301
626	3	7	1/4	Stade de la Beaujoire	282	293	299	293
627	4	7	1/4	Stade Vélodrome	254	309	290	309
628	4	7	1/4	Stade de Gerland	301	302	298	298
629	7	7	1/2	Stade Vélodrome	255	293	309	293
630	8	7	1/2	Stade de France	292	301	298	301
631	11	7	FinaleConsolation	Parc des Princes	293	309	298	298
632	12	7	Finale	Stade de France	285	293	301	301
633	19	6	phase de pool	Giants Stadium	272	337	326	337
634	19	6	phase de pool	Spartan Stadium	320	325	336	325
635	19	6	phase de pool	Giants Stadium	318	323	331	323
636	19	6	phase de pool	Spartan Stadium	279	330	324	\N
637	20	6	phase de pool	Rose Bowl	308	327	329	\N
638	20	6	phase de pool	Foxboro Stadium	321	334	335	334
639	20	6	phase de pool	Rose Bowl	310	333	332	332
640	20	6	phase de pool	Foxboro Stadium	319	322	328	\N
641	23	6	phase de pool	Civic Stadium	313	330	335	335
642	23	6	phase de pool	Jack Kent Cooke Stadium	316	334	324	334
643	23	6	phase de pool	Jack Kent Cooke Stadium	311	322	336	336
644	23	6	phase de pool	Civic Stadium	312	325	328	325
645	24	6	phase de pool	Soldier Field	315	323	329	323
646	24	6	phase de pool	Civic Stadium	317	333	326	333
647	24	6	phase de pool	Soldier Field	318	337	332	337
648	24	6	phase de pool	Civic Stadium	314	327	331	327
649	26	6	phase de pool	Giants Stadium	321	324	335	335
650	26	6	phase de pool	Giants Stadium	313	325	322	325
651	26	6	phase de pool	Soldier Field	272	328	336	336
652	26	6	phase de pool	Soldier Field	309	334	330	334
653	27	6	phase de pool	Jack Kent Cooke Stadium	314	327	323	\N
654	27	6	phase de pool	Jack Kent Cooke Stadium	279	332	326	332
655	27	6	phase de pool	Foxboro Stadium	308	331	329	329
656	27	6	phase de pool	Foxboro Stadium	310	337	333	337
657	30	6	1/4	Spartan Stadium	318	325	335	325
658	30	6	1/4	Spartan Stadium	314	334	336	334
659	1	7	1/4	Jack Kent Cooke Stadium	317	337	327	337
660	1	7	1/4	Jack Kent Cooke Stadium	320	323	332	323
661	4	7	1/2	Stanford Stadium	310	337	323	337
662	4	7	1/2	Foxboro Stadium	272	334	325	325
663	10	7	FinaleConsolation	Rose Bowl	314	323	334	323
664	10	7	Finale	Rose Bowl	318	337	325	337
665	31	5	phase de pool	Seoul World Cup Stadium	255	348	360	360
666	1	6	phase de pool	Niigata Stadium	330	357	341	\N
667	1	6	phase de pool	Ulsan Munsu Football Stadium	333	369	345	345
668	1	6	phase de pool	Sapporo Dome	322	349	359	349
669	2	6	phase de pool	Kashima Stadium	348	338	353	338
670	2	6	phase de pool	Busan Asiad Stadium	336	354	362	\N
671	2	6	phase de pool	Saitama Stadium	346	347	365	\N
672	2	6	phase de pool	Gwangju World Cup Stadium	327	364	361	364
673	3	6	phase de pool	Niigata Stadium	242	344	352	352
674	3	6	phase de pool	Ulsan Munsu Football Stadium	331	340	367	340
675	3	6	phase de pool	Sapporo Dome	328	350	346	350
676	4	6	phase de pool	Gwangju World Cup Stadium	347	342	343	343
677	4	6	phase de pool	Saitama Stadium	334	351	339	\N
678	4	6	phase de pool	Busan Asiad Stadium	343	363	355	363
679	5	6	phase de pool	Kobe Wing Stadium	341	358	366	358
680	5	6	phase de pool	Suwon World Cup Stadium	337	368	356	368
681	5	6	phase de pool	Kashima Stadium	299	349	357	\N
682	6	6	phase de pool	Daegu World Cup Stadium	323	345	360	\N
683	6	6	phase de pool	Saitama Stadium	329	341	359	341
684	6	6	phase de pool	Busan Asiad Stadium	342	348	369	\N
685	7	6	phase de pool	Kobe Wing Stadium	339	365	353	365
686	7	6	phase de pool	Jeonju World Cup Stadium	282	364	354	364
687	7	6	phase de pool	Sapporo Dome	289	338	347	347
688	8	6	phase de pool	Daegu World Cup Stadium	344	362	361	362
689	8	6	phase de pool	Kashima Stadium	340	350	344	344
690	8	6	phase de pool	Jeju World Cup Stadium	326	340	342	340
691	9	6	phase de pool	Miyagi Stadium	325	352	346	352
692	9	6	phase de pool	Incheon Munhak Stadium	324	343	367	\N
693	9	6	phase de pool	International Stadium Yokohama	335	351	358	351
694	10	6	phase de pool	Daegu World Cup Stadium	297	363	368	\N
695	10	6	phase de pool	Ōita Stadium	345	366	339	\N
696	10	6	phase de pool	Jeonju World Cup Stadium	290	356	355	356
697	11	6	phase de pool	Incheon Munhak Stadium	298	345	348	345
698	11	6	phase de pool	Suwon World Cup Stadium	349	360	369	\N
699	11	6	phase de pool	Shizuoka Stadium ECOPA	332	341	349	349
700	11	6	phase de pool	International Stadium Yokohama	338	359	357	357
701	12	6	phase de pool	Nagai Stadium	328	353	347	\N
702	12	6	phase de pool	Miyagi Stadium	255	365	338	\N
703	12	6	phase de pool	Jeju World Cup Stadium	342	361	354	354
704	12	6	phase de pool	Daejeon World Cup Stadium	333	362	364	364
705	13	6	phase de pool	Suwon World Cup Stadium	282	343	340	340
706	13	6	phase de pool	Seoul World Cup Stadium	343	367	342	367
707	13	6	phase de pool	International Stadium Yokohama	334	346	344	346
708	13	6	phase de pool	Ōita Stadium	346	352	350	\N
709	14	6	phase de pool	Shizuoka Stadium ECOPA	299	339	358	339
710	14	6	phase de pool	Nagai Stadium	348	366	351	351
711	14	6	phase de pool	Daejeon World Cup Stadium	242	355	368	355
712	14	6	phase de pool	Incheon Munhak Stadium	344	356	363	363
713	15	6	1/8	Jeju World Cup Stadium	323	349	354	349
714	15	6	1/8	Niigata Stadium	335	345	347	347
715	16	6	1/8	Ōita Stadium	322	365	360	360
716	16	6	1/8	Suwon World Cup Stadium	326	364	357	364
717	17	6	1/8	Jeonju World Cup Stadium	298	352	368	368
718	17	6	1/8	Kobe Wing Stadium	341	340	339	340
719	18	6	1/8	Miyagi Stadium	289	351	367	367
720	18	6	1/8	Daejeon World Cup Stadium	337	363	350	363
721	21	6	1/4	Shizuoka Stadium ECOPA	342	347	340	340
722	21	6	1/4	Ulsan Munsu Football Stadium	290	349	368	349
723	22	6	1/4	Gwangju World Cup Stadium	282	364	363	363
724	22	6	1/4	Nagai Stadium	343	360	367	367
725	25	6	1/2	Seoul World Cup Stadium	297	349	363	349
726	26	6	1/2	Saitama Stadium	299	340	367	340
727	29	6	FinaleConsolation	Daegu World Cup Stadium	333	363	367	367
728	30	6	Finale	International Stadium Yokohama	289	349	340	340
729	20	9	phase de pool	Lincoln Financial Field	319	381	375	381
730	20	9	phase de pool	Lincoln Financial Field	318	379	380	380
731	20	9	phase de pool	Columbus Crew Stadium	314	376	373	376
732	20	9	phase de pool	Columbus Crew Stadium	310	378	370	378
733	21	9	phase de pool	RFK Stadium	354	385	384	385
734	21	9	phase de pool	RFK Stadium	316	372	383	372
735	21	9	phase de pool	Home Depot Center	308	371	382	382
736	21	9	phase de pool	Home Depot Center	272	374	377	374
737	24	9	phase de pool	RFK Stadium	350	381	372	372
738	24	9	phase de pool	Columbus Crew Stadium	353	376	378	376
739	24	9	phase de pool	RFK Stadium	354	375	383	375
740	24	9	phase de pool	Columbus Crew Stadium	318	373	370	373
741	25	9	phase de pool	Home Depot Center	319	377	382	382
742	25	9	phase de pool	Lincoln Financial Field	316	384	380	384
743	25	9	phase de pool	Home Depot Center	310	374	371	\N
744	25	9	phase de pool	Lincoln Financial Field	352	385	379	385
745	27	9	phase de pool	RFK Stadium	351	375	372	\N
746	27	9	phase de pool	Gillette Stadium	316	383	381	381
747	27	9	phase de pool	RFK Stadium	308	370	376	376
748	27	9	phase de pool	Gillette Stadium	314	373	378	373
749	28	9	phase de pool	Columbus Crew Stadium	272	384	379	384
750	28	9	phase de pool	Columbus Crew Stadium	353	380	385	385
751	28	9	phase de pool	PGE Park	350	377	371	377
752	28	9	phase de pool	PGE Park	352	374	382	374
753	1	10	1/4	Gillette Stadium	354	372	384	384
754	1	10	1/4	Gillette Stadium	318	385	381	385
755	2	10	1/4	PGE Park	314	376	382	376
756	2	10	1/4	PGE Park	319	374	373	373
757	5	10	1/2	PGE Park	272	385	376	376
758	5	10	1/2	PGE Park	310	384	373	384
759	11	10	FinaleConsolation	Home Depot Center	316	385	373	385
760	12	10	Finale	Home Depot Center	351	376	384	376
761	9	6	phase de pool	Allianz Arena	360	396	390	396
762	9	6	phase de pool	Arena AufShalke	330	405	393	393
763	10	6	phase de pool	Waldstadion	366	394	404	394
764	10	6	phase de pool	Westfalenstadion	363	414	411	\N
765	10	6	phase de pool	Volksparkstadion	359	387	400	387
766	11	6	phase de pool	Zentralstadion	335	408	403	403
767	11	6	phase de pool	Frankenstadion	367	402	398	402
768	11	6	phase de pool	RheinEnergieStadion	362	386	406	406
769	12	6	phase de pool	Fritz-Walter-Stadion	355	388	401	388
770	12	6	phase de pool	Arena AufShalke	356	417	392	392
771	12	6	phase de pool	Niedersachsenstadion	346	399	397	399
772	13	6	phase de pool	Waldstadion	340	409	413	409
773	13	6	phase de pool	Neckarstadion	361	395	412	\N
774	13	6	phase de pool	Olympiastadion	357	389	391	389
775	14	6	phase de pool	Zentralstadion	358	410	416	410
776	14	6	phase de pool	Allianz Arena	345	415	407	\N
777	14	6	phase de pool	Westfalenstadion	364	396	405	396
778	15	6	phase de pool	Volksparkstadion	324	393	390	393
779	15	6	phase de pool	Frankenstadion	330	394	414	394
780	15	6	phase de pool	Olympiastadion	336	411	404	411
781	16	6	phase de pool	Arena AufShalke	367	387	408	387
782	16	6	phase de pool	Neckarstadion	343	403	400	403
783	16	6	phase de pool	Niedersachsenstadion	363	402	386	\N
784	17	6	phase de pool	Waldstadion	365	406	398	406
785	17	6	phase de pool	RheinEnergieStadion	360	392	397	397
786	17	6	phase de pool	Fritz-Walter-Stadion	362	399	417	\N
787	18	6	phase de pool	Frankenstadion	359	401	391	\N
788	18	6	phase de pool	Allianz Arena	335	389	388	389
789	18	6	phase de pool	Zentralstadion	357	395	409	\N
790	19	6	phase de pool	Westfalenstadion	356	413	412	412
791	19	6	phase de pool	Volksparkstadion	340	407	416	416
792	19	6	phase de pool	Neckarstadion	346	410	415	410
793	20	6	phase de pool	Niedersachsenstadion	363	390	405	405
794	20	6	phase de pool	Olympiastadion	361	393	396	396
795	20	6	phase de pool	Fritz-Walter-Stadion	367	404	414	404
796	20	6	phase de pool	RheinEnergieStadion	358	411	394	\N
797	21	6	phase de pool	Zentralstadion	345	398	386	\N
798	21	6	phase de pool	Arena AufShalke	336	406	402	406
799	21	6	phase de pool	Allianz Arena	366	400	408	400
800	21	6	phase de pool	Waldstadion	364	403	387	\N
801	22	6	phase de pool	Volksparkstadion	357	392	399	399
802	22	6	phase de pool	Frankenstadion	335	397	417	397
803	22	6	phase de pool	Neckarstadion	340	391	388	\N
804	22	6	phase de pool	Westfalenstadion	365	401	389	389
805	23	6	phase de pool	Fritz-Walter-Stadion	324	407	410	410
806	23	6	phase de pool	Olympiastadion	356	416	415	416
807	23	6	phase de pool	Niedersachsenstadion	360	412	409	412
808	23	6	phase de pool	RheinEnergieStadion	362	413	395	395
809	24	6	1/8	Allianz Arena	346	396	411	396
810	24	6	1/8	Zentralstadion	358	387	402	387
811	25	6	1/8	Neckarstadion	359	394	393	394
812	25	6	1/8	Frankenstadion	361	406	403	406
813	26	6	1/8	Fritz-Walter-Stadion	364	399	388	399
814	26	6	1/8	RheinEnergieStadion	357	412	416	416
815	27	6	1/8	Westfalenstadion	336	389	397	389
816	27	6	1/8	Niedersachsenstadion	367	410	395	395
817	30	6	1/4	Olympiastadion	336	396	387	396
818	30	6	1/4	Volksparkstadion	359	399	416	399
819	1	7	1/4	Arena AufShalke	360	394	406	406
820	1	7	1/4	Waldstadion	364	389	395	395
821	4	7	1/2	Westfalenstadion	357	396	399	399
822	5	7	1/2	Allianz Arena	362	406	395	395
823	8	7	FinaleConsolation	Neckarstadion	330	396	406	396
824	9	7	Finale	Olympiastadion	360	399	395	399
825	10	9	phase de pool	Hongkou Football Stadium	316	425	418	425
826	11	9	phase de pool	Chengdu Sports Center	318	433	430	\N
827	11	9	phase de pool	Hongkou Football Stadium	319	427	424	\N
828	11	9	phase de pool	Chengdu Sports Center	375	429	432	\N
829	12	9	phase de pool	Yellow Dragon Sports Center	370	426	419	419
830	12	9	phase de pool	Wuhan Sports Center	374	428	420	420
831	12	9	phase de pool	Yellow Dragon Sports Center	368	431	421	431
832	12	9	phase de pool	Wuhan Sports Center	372	422	423	422
833	14	9	phase de pool	Hongkou Football Stadium	371	418	427	427
834	14	9	phase de pool	Chengdu Sports Center	373	432	433	433
835	14	9	phase de pool	Hongkou Football Stadium	377	424	425	\N
836	14	9	phase de pool	Chengdu Sports Center	316	430	429	430
837	15	9	phase de pool	Yellow Dragon Sports Center	318	421	426	421
838	15	9	phase de pool	Wuhan Sports Center	376	423	428	423
839	15	9	phase de pool	Yellow Dragon Sports Center	375	419	431	\N
840	15	9	phase de pool	Wuhan Sports Center	369	420	422	420
841	17	9	phase de pool	Chengdu Sports Center	372	424	418	424
842	17	9	phase de pool	Yellow Dragon Sports Center	370	425	427	425
843	18	9	phase de pool	Hongkou Football Stadium	376	429	433	433
844	18	9	phase de pool	Tianjin Olympic Center	368	430	432	432
845	20	9	phase de pool	Yellow Dragon Sports Center	373	419	421	\N
846	20	9	phase de pool	Yellow Dragon Sports Center	369	431	426	431
847	20	9	phase de pool	Yellow Dragon Sports Center	319	420	423	420
848	20	9	phase de pool	Tianjin Olympic Center	371	422	428	422
849	22	9	1/4	Wuhan Sports Center	316	425	430	425
850	22	9	1/4	Tianjin Olympic Center	377	433	424	433
851	23	9	1/4	Wuhan Sports Center	373	431	422	431
852	23	9	1/4	Tianjin Olympic Center	368	420	419	420
853	26	9	1/2	Tianjin Olympic Center	371	425	431	425
854	27	9	1/2	Yellow Dragon Sports Center	318	433	420	420
855	30	9	FinaleConsolation	Hongkou Football Stadium	373	431	433	433
856	30	9	Finale	Hongkou Football Stadium	316	425	420	425
857	11	6	phase de pool	Soccer City	384	460	450	\N
858	11	6	phase de pool	Cape Town Stadium	388	465	442	\N
859	12	6	phase de pool	Nelson Mandela Bay Stadium	383	461	445	461
860	12	6	phase de pool	Ellis Park Stadium	390	435	453	435
861	12	6	phase de pool	Royal Bafokeng Stadium	346	441	464	\N
862	13	6	phase de pool	Peter Mokaba Stadium	323	434	459	459
863	13	6	phase de pool	Loftus Versfeld Stadium	379	457	444	444
864	13	6	phase de pool	Moses Mabhida Stadium	366	443	436	443
865	14	6	phase de pool	Soccer City	386	451	440	451
866	14	6	phase de pool	Free State Stadium	380	449	438	449
867	14	6	phase de pool	Cape Town Stadium	357	447	455	\N
868	15	6	phase de pool	Royal Bafokeng Stadium	382	452	458	\N
869	15	6	phase de pool	Nelson Mandela Bay Stadium	362	448	456	\N
870	15	6	phase de pool	Ellis Park Stadium	385	437	454	437
871	16	6	phase de pool	Mbombela Stadium	387	446	439	439
872	16	6	phase de pool	Moses Mabhida Stadium	392	462	463	463
873	16	6	phase de pool	Loftus Versfeld Stadium	358	460	465	465
874	17	6	phase de pool	Soccer City	359	435	461	435
875	17	6	phase de pool	Free State Stadium	343	445	453	445
876	17	6	phase de pool	Peter Mokaba Stadium	378	442	450	450
877	18	6	phase de pool	Nelson Mandela Bay Stadium	391	443	457	457
878	18	6	phase de pool	Ellis Park Stadium	381	459	464	\N
879	18	6	phase de pool	Cape Town Stadium	384	441	434	\N
880	19	6	phase de pool	Moses Mabhida Stadium	379	451	449	451
881	19	6	phase de pool	Royal Bafokeng Stadium	367	444	436	\N
882	19	6	phase de pool	Loftus Versfeld Stadium	362	438	440	440
883	20	6	phase de pool	Free State Stadium	387	458	455	455
884	20	6	phase de pool	Mbombela Stadium	323	447	452	\N
885	20	6	phase de pool	Soccer City	386	437	448	437
886	21	6	phase de pool	Cape Town Stadium	389	456	454	456
887	21	6	phase de pool	Nelson Mandela Bay Stadium	378	439	463	439
888	21	6	phase de pool	Ellis Park Stadium	388	462	446	462
889	22	6	phase de pool	Free State Stadium	343	442	460	460
890	22	6	phase de pool	Royal Bafokeng Stadium	385	450	465	465
891	22	6	phase de pool	Peter Mokaba Stadium	384	445	435	435
892	22	6	phase de pool	Moses Mabhida Stadium	380	453	461	\N
893	23	6	phase de pool	Nelson Mandela Bay Stadium	390	459	441	441
894	23	6	phase de pool	Loftus Versfeld Stadium	359	464	434	464
895	23	6	phase de pool	Mbombela Stadium	362	436	457	436
896	23	6	phase de pool	Soccer City	346	444	443	443
897	24	6	phase de pool	Peter Mokaba Stadium	388	455	452	\N
898	24	6	phase de pool	Ellis Park Stadium	392	458	447	458
899	24	6	phase de pool	Cape Town Stadium	389	438	451	451
900	24	6	phase de pool	Royal Bafokeng Stadium	382	440	449	449
901	25	6	phase de pool	Mbombela Stadium	391	454	448	448
902	25	6	phase de pool	Moses Mabhida Stadium	357	456	437	\N
903	25	6	phase de pool	Loftus Versfeld Stadium	366	439	462	462
904	25	6	phase de pool	Free State Stadium	379	463	446	\N
905	26	6	1/8	Nelson Mandela Bay Stadium	390	465	461	465
906	26	6	1/8	Royal Bafokeng Stadium	385	464	444	444
907	27	6	1/8	Free State Stadium	362	443	441	443
908	27	6	1/8	Soccer City	367	435	450	435
909	28	6	1/8	Moses Mabhida Stadium	391	451	458	451
910	28	6	1/8	Ellis Park Stadium	392	437	439	437
911	29	6	1/8	Loftus Versfeld Stadium	359	455	449	455
912	29	6	1/8	Cape Town Stadium	379	462	456	462
913	2	7	1/4	Nelson Mandela Bay Stadium	388	451	437	451
914	2	7	1/4	Soccer City	380	465	444	465
915	3	7	1/4	Cape Town Stadium	384	435	443	443
916	3	7	1/4	Ellis Park Stadium	323	455	462	462
917	6	7	1/2	Cape Town Stadium	384	465	451	451
918	7	7	1/2	Moses Mabhida Stadium	385	443	462	462
919	10	7	FinaleConsolation	Nelson Mandela Bay Stadium	357	465	443	443
920	11	7	Finale	Soccer City	392	451	462	462
921	26	6	phase de pool	Rhein-Neckar-Arena	319	477	472	472
922	26	6	phase de pool	Olympiastadion	399	473	468	473
923	27	6	phase de pool	Ruhrstadion	398	474	476	474
924	27	6	phase de pool	Volkswagen Arena	402	475	470	\N
925	28	6	phase de pool	BayArena	396	469	480	480
926	28	6	phase de pool	Rudolf-Harbig-Stadion	403	481	478	481
927	29	6	phase de pool	Impuls Arena	393	479	471	479
928	29	6	phase de pool	Borussia-Park	377	467	466	467
929	30	6	phase de pool	Ruhrstadion	397	468	472	472
930	30	6	phase de pool	Waldstadion	395	473	477	473
931	1	7	phase de pool	BayArena	401	474	475	474
932	1	7	phase de pool	Rudolf-Harbig-Stadion	400	476	470	470
933	2	7	phase de pool	Impuls Arena	394	478	480	480
934	2	7	phase de pool	Rhein-Neckar-Arena	371	481	469	481
935	3	7	phase de pool	Ruhrstadion	373	466	471	466
936	3	7	phase de pool	Volkswagen Arena	319	467	479	467
937	5	7	phase de pool	Impuls Arena	396	470	474	470
938	5	7	phase de pool	Rhein-Neckar-Arena	377	476	475	\N
939	5	7	phase de pool	Rudolf-Harbig-Stadion	404	468	477	477
940	5	7	phase de pool	Borussia-Park	398	472	473	473
941	6	7	phase de pool	BayArena	394	466	479	466
942	6	7	phase de pool	Waldstadion	403	471	467	467
943	6	7	phase de pool	Ruhrstadion	401	478	469	\N
944	6	7	phase de pool	Volkswagen Arena	397	480	481	480
945	9	7	1/4	BayArena	377	470	472	472
946	9	7	1/4	Volkswagen Arena	393	473	474	474
947	10	7	1/4	Impuls Arena	402	480	466	480
948	10	7	1/4	Rudolf-Harbig-Stadion	399	467	481	481
949	13	7	1/2	Borussia-Park	398	472	481	481
950	13	7	1/2	Waldstadion	396	474	480	474
951	16	7	FinaleConsolation	Rhein-Neckar-Arena	319	480	472	480
952	17	7	Finale	Waldstadion	403	474	481	474
953	12	6	phase de pool	Arena Corinthians	388	487	492	487
954	13	6	phase de pool	Arena das Dunas	421	504	488	504
955	13	6	phase de pool	Arena Fonte Nova	420	510	505	505
956	13	6	phase de pool	Arena Pantanal	408	489	484	489
957	14	6	phase de pool	Estádio Mineirão	411	490	498	490
958	14	6	phase de pool	Estádio Castelão	406	513	491	491
959	14	6	phase de pool	Arena da Amazônia	413	494	501	501
960	14	6	phase de pool	Arena Pernambuco	416	502	503	502
961	15	6	phase de pool	Estádio Nacional	384	511	493	511
962	15	6	phase de pool	Estádio Beira-Rio	419	495	499	495
963	15	6	phase de pool	Estádio do Maracanã	405	483	486	483
964	16	6	phase de pool	Arena Fonte Nova	414	496	507	496
965	16	6	phase de pool	Arena da Baixada	424	500	506	\N
966	16	6	phase de pool	Arena das Dunas	409	497	512	512
967	17	6	phase de pool	Estádio Mineirão	366	485	482	485
968	17	6	phase de pool	Estádio Castelão	407	487	504	\N
969	17	6	phase de pool	Arena Pantanal	417	508	509	\N
970	18	6	phase de pool	Estádio Beira-Rio	412	484	505	505
971	18	6	phase de pool	Estádio do Maracanã	411	510	489	489
972	18	6	phase de pool	Arena da Amazônia	418	488	492	492
973	19	6	phase de pool	Estádio Nacional	392	490	502	490
974	19	6	phase de pool	Arena Corinthians	423	513	494	513
975	19	6	phase de pool	Arena das Dunas	405	503	498	\N
976	20	6	phase de pool	Arena Pernambuco	416	501	491	491
977	20	6	phase de pool	Arena Fonte Nova	413	511	495	495
978	20	6	phase de pool	Arena da Baixada	425	499	493	493
979	21	6	phase de pool	Estádio Mineirão	414	483	500	483
980	21	6	phase de pool	Estádio Castelão	419	496	497	\N
981	21	6	phase de pool	Arena Pantanal	415	506	486	506
982	22	6	phase de pool	Estádio do Maracanã	406	485	508	485
983	22	6	phase de pool	Estádio Beira-Rio	421	509	482	482
984	22	6	phase de pool	Arena da Amazônia	417	512	507	\N
985	23	6	phase de pool	Arena da Baixada	422	484	510	510
986	23	6	phase de pool	Arena Corinthians	410	505	489	505
987	23	6	phase de pool	Estádio Nacional	409	488	487	487
988	23	6	phase de pool	Arena Pernambuco	384	492	504	504
989	24	6	phase de pool	Estádio Mineirão	412	491	494	\N
990	24	6	phase de pool	Arena das Dunas	366	501	513	513
991	24	6	phase de pool	Arena Pantanal	418	503	490	490
992	24	6	phase de pool	Estádio Castelão	424	498	502	498
993	25	6	phase de pool	Arena Fonte Nova	423	486	500	486
994	25	6	phase de pool	Estádio Beira-Rio	420	506	483	483
995	25	6	phase de pool	Arena da Amazônia	417	499	511	511
996	25	6	phase de pool	Estádio do Maracanã	408	493	495	\N
997	26	6	phase de pool	Estádio Nacional	422	507	497	507
998	26	6	phase de pool	Arena Pernambuco	384	512	496	496
999	26	6	phase de pool	Arena da Baixada	407	482	508	\N
1000	26	6	phase de pool	Arena Corinthians	425	509	485	485
1001	28	6	1/8	Estádio Mineirão	392	487	489	487
1002	28	6	1/8	Estádio do Maracanã	413	490	513	490
1003	29	6	1/8	Estádio Castelão	418	505	504	505
1004	29	6	1/8	Arena Pernambuco	425	491	498	491
1005	30	6	1/8	Estádio Nacional	411	495	506	495
1006	30	6	1/8	Estádio Beira-Rio	419	496	482	496
1007	1	7	1/8	Arena Corinthians	409	483	511	483
1008	1	7	1/8	Arena Fonte Nova	412	485	512	485
1009	4	7	1/4	Estádio do Maracanã	417	495	496	496
1010	4	7	1/4	Estádio Castelão	423	487	490	487
1011	5	7	1/4	Estádio Nacional	420	483	485	483
1012	5	7	1/4	Arena Fonte Nova	384	505	491	505
1013	8	7	1/2	Estádio Mineirão	366	487	496	496
1014	9	7	1/2	Arena Corinthians	407	505	483	483
1015	12	7	FinaleConsolation	Estádio Nacional	412	487	505	505
1016	13	7	Finale	Estádio do Maracanã	420	496	483	496
1017	6	6	phase de pool	Commonwealth Stadium	438	517	518	517
1018	6	6	phase de pool	Commonwealth Stadium	393	529	528	528
1019	7	6	phase de pool	TD Place Stadium	432	531	536	531
1020	7	6	phase de pool	TD Place Stadium	396	524	525	524
1021	8	6	phase de pool	Investors Group Field	440	534	530	\N
1022	8	6	phase de pool	BC Place	433	516	521	516
1023	8	6	phase de pool	Investors Group Field	442	537	514	537
1024	8	6	phase de pool	BC Place	443	526	535	526
1025	9	6	phase de pool	Moncton Stadium	437	523	522	523
1026	9	6	phase de pool	Olympic Stadium	428	533	520	\N
1027	9	6	phase de pool	Moncton Stadium	400	519	527	\N
1028	9	6	phase de pool	Olympic Stadium	441	515	532	515
1029	11	6	phase de pool	Commonwealth Stadium	436	518	528	518
1030	11	6	phase de pool	TD Place Stadium	426	524	531	\N
1031	11	6	phase de pool	Commonwealth Stadium	403	517	529	\N
1032	11	6	phase de pool	TD Place Stadium	429	525	536	536
1033	12	6	phase de pool	BC Place	431	535	521	535
1034	12	6	phase de pool	Investors Group Field	430	514	530	514
1035	12	6	phase de pool	BC Place	434	526	516	526
1036	12	6	phase de pool	Investors Group Field	445	537	534	\N
1037	13	6	phase de pool	Moncton Stadium	439	523	519	519
1038	13	6	phase de pool	Olympic Stadium	396	515	533	515
1039	13	6	phase de pool	Moncton Stadium	432	522	527	522
1040	13	6	phase de pool	Olympic Stadium	444	532	520	\N
1041	15	6	phase de pool	Investors Group Field	435	536	524	524
1042	15	6	phase de pool	Moncton Stadium	428	525	531	531
1043	15	6	phase de pool	Investors Group Field	433	518	529	\N
1044	15	6	phase de pool	Olympic Stadium	440	528	517	\N
1045	16	6	phase de pool	Commonwealth Stadium	442	535	516	516
1046	16	6	phase de pool	Investors Group Field	427	521	526	526
1047	16	6	phase de pool	BC Place	438	530	537	537
1048	16	6	phase de pool	Commonwealth Stadium	443	514	534	\N
1049	17	6	phase de pool	Olympic Stadium	396	522	519	522
1050	17	6	phase de pool	TD Place Stadium	445	527	523	523
1051	17	6	phase de pool	TD Place Stadium	432	532	533	532
1052	17	6	phase de pool	Moncton Stadium	437	520	515	515
1053	20	6	1/8	TD Place Stadium	440	524	534	524
1054	20	6	1/8	Commonwealth Stadium	403	518	516	518
1055	21	6	1/8	Moncton Stadium	426	515	514	514
1056	21	6	1/8	Olympic Stadium	428	523	532	523
1057	21	6	1/8	BC Place	432	517	535	517
1058	22	6	1/8	TD Place Stadium	441	531	522	522
1059	22	6	1/8	Commonwealth Stadium	430	537	519	537
1060	23	6	1/8	BC Place	443	526	528	526
1061	26	6	1/4	Olympic Stadium	396	524	523	524
1062	26	6	1/4	TD Place Stadium	444	518	537	537
1063	27	6	1/4	Commonwealth Stadium	438	514	526	526
1064	27	6	1/4	BC Place	442	522	517	522
1065	30	6	1/2	Olympic Stadium	426	537	524	537
1066	1	7	1/2	Commonwealth Stadium	432	526	522	526
1067	4	7	FinaleConsolation	Commonwealth Stadium	440	524	522	522
1068	5	7	Finale	BC Place	438	537	526	537
1069	14	6	phase de pool	Luzhniki Stadium	417	560	561	560
1070	15	6	phase de pool	Central Stadium	413	546	569	569
1071	15	6	phase de pool	Krestovsky Stadium	407	554	551	551
1072	15	6	phase de pool	Fisht Olympic Stadium	458	559	565	\N
1073	16	6	phase de pool	Kazan Arena	448	548	539	548
1074	16	6	phase de pool	Otkritie Arena	454	538	550	\N
1075	16	6	phase de pool	Mordovia Arena	410	557	545	545
1076	16	6	phase de pool	Kaliningrad Stadium	419	544	555	544
1077	17	6	phase de pool	Samara Arena	449	543	563	563
1078	17	6	phase de pool	Luzhniki Stadium	450	549	553	553
1079	17	6	phase de pool	Rostov Arena	457	541	567	\N
1080	18	6	phase de pool	Nizhny Novgorod Stadium	405	566	564	566
1081	18	6	phase de pool	Fisht Olympic Stadium	459	540	556	540
1082	18	6	phase de pool	Volgograd Arena	421	568	547	547
1083	19	6	phase de pool	Mordovia Arena	460	542	552	552
1084	19	6	phase de pool	Otkritie Arena	422	558	562	562
1085	19	6	phase de pool	Krestovsky Stadium	446	560	546	560
1086	20	6	phase de pool	Luzhniki Stadium	411	559	554	559
1087	20	6	phase de pool	Rostov Arena	461	569	561	569
1088	20	6	phase de pool	Kazan Arena	448	551	565	565
1089	21	6	phase de pool	Samara Arena	456	545	539	\N
1090	21	6	phase de pool	Central Stadium	452	548	557	548
1091	21	6	phase de pool	Nizhny Novgorod Stadium	384	538	544	544
1092	22	6	phase de pool	Krestovsky Stadium	413	541	543	541
1093	22	6	phase de pool	Volgograd Arena	447	555	550	555
1094	22	6	phase de pool	Kaliningrad Stadium	406	563	567	567
1095	23	6	phase de pool	Otkritie Arena	455	540	568	540
1096	23	6	phase de pool	Rostov Arena	414	564	553	553
1097	23	6	phase de pool	Fisht Olympic Stadium	454	549	566	549
1098	24	6	phase de pool	Nizhny Novgorod Stadium	451	547	556	547
1099	24	6	phase de pool	Central Stadium	458	552	562	\N
1100	24	6	phase de pool	Kazan Arena	457	558	542	542
1101	25	6	phase de pool	Volgograd Arena	421	561	546	561
1102	25	6	phase de pool	Samara Arena	449	569	560	569
1103	25	6	phase de pool	Kaliningrad Stadium	384	565	554	\N
1104	25	6	phase de pool	Mordovia Arena	446	551	559	\N
1105	26	6	phase de pool	Fisht Olympic Stadium	453	539	557	557
1106	26	6	phase de pool	Luzhniki Stadium	419	545	548	\N
1107	26	6	phase de pool	Rostov Arena	456	550	544	544
1108	26	6	phase de pool	Krestovsky Stadium	407	555	538	538
1109	27	6	phase de pool	Kazan Arena	411	564	549	564
1110	27	6	phase de pool	Central Stadium	417	553	566	566
1111	27	6	phase de pool	Otkritie Arena	450	563	541	541
1112	27	6	phase de pool	Nizhny Novgorod Stadium	461	567	543	\N
1113	28	6	phase de pool	Volgograd Arena	459	552	558	558
1114	28	6	phase de pool	Samara Arena	414	562	542	542
1115	28	6	phase de pool	Kaliningrad Stadium	460	547	540	540
1116	28	6	phase de pool	Mordovia Arena	422	556	568	568
1117	30	6	1/8	Kazan Arena	450	548	538	548
1118	30	6	1/8	Fisht Olympic Stadium	457	569	559	569
1119	1	7	1/8	Luzhniki Stadium	413	565	560	560
1120	1	7	1/8	Nizhny Novgorod Stadium	417	544	545	544
1121	2	7	1/8	Samara Arena	458	541	553	541
1122	2	7	1/8	Rostov Arena	449	540	552	540
1123	3	7	1/8	Krestovsky Stadium	460	566	567	566
1124	3	7	1/8	Otkritie Arena	411	542	547	547
1125	6	7	1/4	Nizhny Novgorod Stadium	417	569	548	548
1126	6	7	1/4	Kazan Arena	414	541	540	540
1127	7	7	1/4	Samara Arena	413	566	547	547
1128	7	7	1/4	Fisht Olympic Stadium	419	560	544	544
1129	10	7	1/2	Krestovsky Stadium	448	548	540	548
1130	11	7	1/2	Luzhniki Stadium	407	544	547	544
1131	14	7	FinaleConsolation	Krestovsky Stadium	450	540	547	540
1132	15	7	Finale	Luzhniki Stadium	417	548	544	548
1133	7	6	phase de pool	Parc des Princes	442	578	589	578
1134	8	6	phase de pool	Roazhon Park	464	579	576	579
1135	8	6	phase de pool	Stade Océane	466	590	588	590
1136	8	6	phase de pool	Stade Auguste-Delaune	469	586	585	586
1137	9	6	phase de pool	Stade du Hainaut	427	571	580	580
1138	9	6	phase de pool	Stade des Alpes	468	572	581	572
1139	9	6	phase de pool	Allianz Riviera	462	577	587	577
1140	10	6	phase de pool	Parc des Princes	430	570	582	\N
1141	10	6	phase de pool	Stade de la Mosson	440	574	573	574
1142	11	6	phase de pool	Stade Océane	463	584	583	583
1143	11	6	phase de pool	Roazhon Park	443	575	591	591
1144	11	6	phase de pool	Stade Auguste-Delaune	467	593	592	593
1145	12	6	phase de pool	Stade des Alpes	471	585	589	585
1146	12	6	phase de pool	Stade du Hainaut	438	579	590	579
1147	12	6	phase de pool	Allianz Riviera	403	578	586	578
1148	13	6	phase de pool	Stade de la Mosson	441	571	572	571
1149	13	6	phase de pool	Parc des Princes	433	588	576	576
1150	14	6	phase de pool	Roazhon Park	473	582	587	582
1151	14	6	phase de pool	Stade Auguste-Delaune	432	581	580	580
1152	14	6	phase de pool	Stade Océane	439	577	570	577
1153	15	6	phase de pool	Stade du Hainaut	472	583	573	583
1154	15	6	phase de pool	Stade des Alpes	474	574	584	574
1155	16	6	phase de pool	Allianz Riviera	470	591	592	591
1156	16	6	phase de pool	Parc des Princes	468	593	575	593
1157	17	6	phase de pool	Stade Océane	463	576	590	\N
1158	17	6	phase de pool	Stade de la Mosson	465	588	579	579
1159	17	6	phase de pool	Roazhon Park	427	585	578	578
1160	17	6	phase de pool	Stade Auguste-Delaune	464	589	586	586
1161	18	6	phase de pool	Stade du Hainaut	443	580	572	572
1162	18	6	phase de pool	Stade des Alpes	433	581	571	571
1163	19	6	phase de pool	Allianz Riviera	442	582	577	577
1164	19	6	phase de pool	Parc des Princes	440	587	570	\N
1165	20	6	phase de pool	Stade de la Mosson	438	573	584	573
1166	20	6	phase de pool	Stade Auguste-Delaune	430	583	574	583
1167	20	6	phase de pool	Stade Océane	471	591	593	593
1168	20	6	phase de pool	Roazhon Park	432	592	575	575
1169	22	6	1/8	Stade des Alpes	474	579	585	579
1170	22	6	1/8	Allianz Riviera	468	586	571	586
1171	23	6	1/8	Stade du Hainaut	439	577	573	577
1172	23	6	1/8	Stade Océane	464	578	572	578
1173	24	6	1/8	Stade Auguste-Delaune	433	590	593	593
1174	24	6	1/8	Parc des Princes	469	591	574	591
1175	25	6	1/8	Stade de la Mosson	463	580	576	580
1176	25	6	1/8	Roazhon Park	427	583	582	583
1177	27	6	1/4	Stade Océane	443	586	577	577
1178	28	6	1/4	Parc des Princes	438	578	593	593
1179	29	6	1/4	Stade du Hainaut	442	580	583	583
1180	29	6	1/4	Roazhon Park	430	579	591	591
1181	2	7	1/2	Parc Olympique Lyonnais	463	577	593	593
1182	3	7	1/2	Parc Olympique Lyonnais	464	583	591	583
1183	6	7	FinaleConsolation	Allianz Riviera	471	577	591	591
1184	7	7	Finale	Parc Olympique Lyonnais	430	593	583	593
1185	20	11	phase de pool	Al Bayt Stadium	486	615	603	603
1186	21	11	phase de pool	Khalifa International Stadium	478	604	608	604
1187	21	11	phase de pool	Al Thumama Stadium	488	617	612	612
1188	21	11	phase de pool	Ahmad bin Ali Stadium	475	623	625	\N
1189	22	11	phase de pool	Lusail Stadium	493	594	616	616
1190	22	11	phase de pool	Education City Stadium	457	602	622	\N
1191	22	11	phase de pool	Stadium 974	477	610	613	\N
1192	22	11	phase de pool	Al Janoub Stadium	482	605	595	605
1193	23	11	phase de pool	Al Bayt Stadium	487	611	601	\N
1194	23	11	phase de pool	Khalifa International Stadium	476	606	609	609
1195	23	11	phase de pool	Al Thumama Stadium	452	620	600	620
1196	23	11	phase de pool	Ahmad bin Ali Stadium	459	596	599	596
1197	24	11	phase de pool	Al Janoub Stadium	491	621	598	621
1198	24	11	phase de pool	Education City Stadium	461	624	619	\N
1199	24	11	phase de pool	Stadium 974	479	614	607	614
1200	24	11	phase de pool	Lusail Stadium	450	597	618	597
1201	25	11	phase de pool	Ahmad bin Ali Stadium	480	625	608	608
1202	25	11	phase de pool	Al Thumama Stadium	456	615	617	617
1203	25	11	phase de pool	Khalifa International Stadium	481	612	603	\N
1204	25	11	phase de pool	Al Bayt Stadium	492	604	623	\N
1205	26	11	phase de pool	Al Janoub Stadium	489	622	595	595
1206	26	11	phase de pool	Education City Stadium	488	613	616	613
1207	26	11	phase de pool	Stadium 974	454	605	602	605
1208	26	11	phase de pool	Lusail Stadium	486	594	610	594
1209	27	11	phase de pool	Ahmad bin Ali Stadium	485	609	600	600
1210	27	11	phase de pool	Al Thumama Stadium	457	596	611	611
1211	27	11	phase de pool	Khalifa International Stadium	484	601	599	601
1212	27	11	phase de pool	Al Bayt Stadium	483	620	606	\N
1213	28	11	phase de pool	Al Janoub Stadium	452	598	618	\N
1214	28	11	phase de pool	Education City Stadium	490	619	607	607
1215	28	11	phase de pool	Stadium 974	476	597	621	597
1216	28	11	phase de pool	Lusail Stadium	450	614	624	614
1217	29	11	phase de pool	Khalifa International Stadium	461	603	617	617
1218	29	11	phase de pool	Al Bayt Stadium	410	612	615	612
1219	29	11	phase de pool	Al Thumama Stadium	456	608	623	623
1220	29	11	phase de pool	Ahmad bin Ali Stadium	493	625	604	604
1221	30	11	phase de pool	Al Janoub Stadium	481	595	602	595
1222	30	11	phase de pool	Education City Stadium	447	622	605	622
1223	30	11	phase de pool	Stadium 974	483	613	594	594
1224	30	11	phase de pool	Lusail Stadium	485	616	610	610
1225	1	12	phase de pool	Al Thumama Stadium	478	599	611	611
1226	1	12	phase de pool	Ahmad bin Ali Stadium	490	601	596	\N
1227	1	12	phase de pool	Al Bayt Stadium	430	600	606	606
1228	1	12	phase de pool	Khalifa International Stadium	482	609	620	609
1229	2	12	phase de pool	Al Janoub Stadium	489	607	624	624
1230	2	12	phase de pool	Education City Stadium	491	619	614	619
1231	2	12	phase de pool	Lusail Stadium	479	598	597	598
1232	2	12	phase de pool	Stadium 974	487	618	621	621
1233	3	12	1/8	Khalifa International Stadium	488	612	623	612
1234	3	12	1/8	Ahmad bin Ali Stadium	454	594	595	594
1235	4	12	1/8	Al Thumama Stadium	492	605	613	605
1236	4	12	1/8	Al Bayt Stadium	476	604	617	604
1237	5	12	1/8	Al Janoub Stadium	479	609	601	601
1238	5	12	1/8	Stadium 974	461	597	619	597
1239	6	12	1/8	Education City Stadium	487	611	620	611
1240	6	12	1/8	Lusail Stadium	457	614	621	614
1241	9	12	1/4	Education City Stadium	485	601	597	601
1242	9	12	1/4	Lusail Stadium	456	612	594	594
1243	10	12	1/4	Al Thumama Stadium	491	611	614	611
1244	10	12	1/4	Al Bayt Stadium	488	604	605	605
1245	13	12	1/2	Lusail Stadium	486	594	601	594
1246	14	12	1/2	Al Bayt Stadium	457	605	611	605
1247	17	12	FinaleConsolation	Khalifa International Stadium	475	601	611	601
1248	18	12	Finale	Lusail Stadium	454	594	605	594
\.


--
-- Data for Name: possede; Type: TABLE DATA; Schema: public; Owner: wcuser
--

COPY public.possede (equipe_id, joueur_id) FROM stdin;
1	69244
1	23160
1	99230
1	41921
1	22739
1	30720
1	30543
1	23897
1	60505
1	25760
1	49556
1	91238
1	58537
1	24312
1	70166
1	49151
1	44916
1	21441
1	56486
1	56908
1	37326
1	76546
2	92795
2	20690
2	40714
2	41990
2	97126
2	93713
2	41710
2	45315
2	16891
2	61253
2	44475
2	74839
2	46390
2	28503
2	69286
2	85443
3	43807
3	62751
3	95008
3	97354
3	16019
3	36835
3	69877
3	61667
3	48216
3	92600
3	84833
3	92838
3	93364
3	56114
3	35684
3	369
3	67934
4	13299
4	70170
4	11648
4	81166
4	58460
4	52323
4	708
4	49818
4	29865
4	92427
4	16656
4	72889
4	30679
4	49633
4	83987
4	10526
4	52064
4	32535
4	38379
4	91171
4	82422
4	26796
4	28745
4	22493
5	95800
5	33635
5	54301
5	88235
5	1278
5	41928
5	32614
5	7122
5	66860
5	19195
5	97943
5	85142
5	49261
5	89829
5	8459
5	10927
5	28795
5	61338
5	65664
6	68817
6	77318
6	83054
6	10604
6	53878
6	99087
6	73308
6	5470
6	89688
6	60620
6	67332
6	58728
6	62322
6	50248
6	2281
6	48345
7	36379
7	33560
7	94135
7	33321
7	43777
7	41910
7	31066
7	84297
7	21313
7	27734
7	31687
7	58196
7	8566
7	89481
7	17565
7	83291
7	65099
8	33814
8	35834
8	30741
8	78377
8	61392
8	51301
8	68567
8	37309
8	21707
8	8814
8	54557
8	86082
8	65504
8	64697
8	4623
8	98075
8	11035
8	9057
8	4417
8	51624
8	6201
8	51390
9	35875
9	45407
9	79515
9	7526
9	45649
9	64036
9	38495
9	29687
9	93477
9	44526
9	57115
9	71799
9	19170
9	6866
9	8526
9	27561
9	36167
9	66691
9	44010
9	89076
9	41536
9	36243
10	99417
10	62376
10	27752
10	91295
10	20672
10	70294
10	9282
10	7972
10	2455
10	18615
10	51872
10	81554
10	22907
10	85622
10	22304
11	58795
11	94425
11	6424
11	12437
11	37361
11	99522
11	733
11	85569
11	65185
11	25155
11	46121
11	71973
11	47437
11	4110
11	49855
11	56459
12	63826
12	57352
12	63987
12	47453
12	76186
12	54697
12	18628
12	38674
12	53856
12	39785
12	31959
12	49150
12	55304
12	76270
12	93278
12	41238
12	63026
12	98216
12	93344
12	44201
12	86932
12	17569
13	72808
13	43734
13	13261
13	15059
13	44887
13	24808
13	75929
13	10671
13	19712
13	91900
13	94965
13	74878
13	62267
13	55273
13	43349
13	59061
13	33565
14	32516
14	42498
14	11019
14	21951
14	5185
14	98837
14	61839
14	33940
14	82803
14	2358
14	32246
14	5772
14	64351
14	15166
14	16377
14	94114
14	33461
14	95620
15	51668
15	37758
15	72888
15	28322
15	32150
15	94617
15	51711
15	92579
15	48419
15	14775
15	17740
15	87474
15	14790
15	5609
15	11865
15	71630
15	30750
15	97102
15	65339
15	39159
15	19490
15	5719
16	20690
16	57945
16	56476
16	27187
16	89966
16	31088
16	28338
16	61253
16	97896
16	356
16	3817
16	93825
16	51930
16	11200
16	81829
16	87214
16	38767
16	97759
16	32287
16	69286
16	85443
16	1972
17	63886
17	32881
17	91413
17	7398
17	3130
17	52951
17	48079
17	93712
17	72889
17	9730
17	35048
17	66864
17	70690
17	77114
17	32535
17	85795
17	8627
17	3576
17	93990
18	94788
18	76056
18	28531
18	68716
18	70254
18	19582
18	88929
18	64425
18	53978
18	30773
18	60513
18	70970
18	52528
18	51219
18	23820
18	94005
18	58983
18	57162
18	21644
18	13470
18	64843
18	42431
19	87740
19	78354
19	62813
19	76014
19	96407
19	82850
19	28239
19	44834
19	18819
19	66692
19	55444
19	45036
19	13156
19	17075
19	46343
19	12336
19	1246
19	48383
19	96789
19	67758
20	9225
20	93801
20	45731
20	52655
20	36153
20	10604
20	53878
20	30130
20	84475
20	26041
20	45865
20	5470
20	26292
20	59589
20	69033
20	67332
20	70804
20	49701
20	50248
20	46249
20	2281
20	13166
21	82536
21	54695
21	81440
21	27770
21	77348
21	74210
21	27139
21	69645
21	99592
21	56231
21	90001
21	24404
21	4241
21	74349
21	38753
21	60828
21	30818
21	72423
21	53238
21	92333
21	86518
21	85695
22	18927
22	81185
22	31849
22	26210
22	70689
22	81445
22	54489
22	23517
22	32085
22	10473
22	89034
22	9142
22	14531
22	60980
22	29081
22	99214
22	37684
22	38660
22	42669
22	60977
22	91259
22	11520
23	22402
23	80654
23	60679
23	40103
23	84232
23	56674
23	77995
23	57546
23	30720
23	39512
23	76282
23	3545
23	16965
23	93906
23	34536
23	25760
23	58691
23	3638
23	10605
23	30373
23	56703
23	95210
24	51120
24	74001
24	69466
24	8052
24	84091
24	81649
24	75398
24	19181
24	67910
24	19627
24	86401
24	85884
24	28465
24	84890
24	44776
24	24944
24	29803
24	20598
24	55392
24	84101
24	83478
24	57256
25	76189
25	58656
25	28958
25	92768
25	62376
25	83778
25	55859
25	29524
25	55855
25	49480
25	77815
25	41753
25	36734
25	70432
25	38049
25	67464
25	57363
25	89198
25	49773
25	22907
25	79776
25	70088
26	47714
26	67537
26	91286
26	29275
26	85952
26	54892
26	89086
26	17824
26	64059
26	12120
26	69133
26	3613
26	41247
26	53344
26	90409
26	47982
26	87531
26	40752
26	14976
26	17732
26	63912
26	7867
27	23401
27	45925
27	22714
27	65347
27	12745
27	62095
27	19096
27	83366
27	92190
27	66504
27	22732
27	90839
27	96043
27	1918
27	79374
27	94204
27	2091
27	18347
27	67034
27	16727
27	19469
27	9085
27	76001
28	85334
28	64427
28	6791
28	21616
28	94058
28	61867
28	53059
28	49691
28	41260
28	49305
28	97291
28	87405
28	31231
28	58205
28	88416
28	35043
28	85276
28	17489
28	15994
28	96627
28	71546
28	13267
28	44740
29	37867
29	64188
29	31804
29	75829
29	65285
29	37361
29	99522
29	85569
29	51225
29	64948
29	71808
29	65974
29	74221
29	16062
29	25155
29	17263
29	64536
29	57295
29	91378
30	20690
30	63553
30	84927
30	33714
30	27187
30	17309
30	73403
30	94481
30	44080
30	24202
30	44854
30	3499
30	11957
30	46631
30	69703
30	95279
30	38767
30	6477
30	57062
30	32038
30	32287
30	85443
31	279
31	41619
31	14044
31	24911
31	14381
31	56060
31	77661
31	92554
31	9730
31	14047
31	35048
31	16663
31	35561
31	68604
31	88147
31	85795
31	70927
31	81322
31	44339
31	5159
31	76392
31	42205
32	23003
32	91946
32	90611
32	50445
32	29608
32	72041
32	82026
32	77302
32	46059
32	56223
32	43737
32	19947
32	77922
32	47473
32	99758
33	94788
33	83399
33	76056
33	91890
33	48049
33	70254
33	41835
33	24836
33	64425
33	53978
33	55632
33	29652
33	60513
33	38048
33	33048
33	52528
33	51219
33	30507
33	3127
33	47402
33	15892
33	27945
34	65883
34	16278
34	51934
34	72195
34	56198
34	38291
34	5443
34	8131
34	3631
34	59945
34	19995
34	52233
34	89666
34	92120
34	3175
34	69801
34	37048
34	38536
34	67536
35	93801
35	69619
35	9795
35	79828
35	50527
35	92301
35	52655
35	94763
35	10604
35	65422
35	18863
35	78235
35	38344
35	26887
35	36564
35	59589
35	67332
35	70804
35	16634
35	46249
35	2281
35	70720
36	81440
36	15763
36	25957
36	71483
36	53466
36	90001
36	24404
36	21402
36	82099
36	38753
36	281
36	60828
36	47513
36	46036
36	17740
36	14790
36	53238
36	58969
36	43378
36	30750
36	86518
36	39159
37	58088
37	1726
37	81185
37	4962
37	31849
37	70689
37	53740
37	25927
37	54489
37	36957
37	10473
37	52028
37	89034
37	37357
37	60980
37	99214
37	37684
37	24305
37	60977
37	33184
37	11520
37	67652
38	79580
38	62660
38	85283
38	94715
38	9916
38	76066
38	7254
38	39512
38	58640
38	97762
38	7131
38	79327
38	93906
38	34536
38	58691
38	95291
38	98926
38	30716
38	74793
38	65885
38	27048
38	82806
39	51120
39	1561
39	92370
39	61401
39	27345
39	92587
39	22639
39	21727
39	39735
39	71910
39	67910
39	29879
39	60379
39	61772
39	85884
39	21967
39	44776
39	24944
39	91177
39	55392
39	83478
39	57256
40	39938
40	44129
40	27507
40	17838
40	54406
40	7024
40	19044
40	47235
40	67971
40	36967
40	60666
40	7358
40	64492
40	32828
40	67226
40	49779
40	79093
40	6148
40	51305
40	27380
40	24384
40	52552
41	1935
41	96120
41	65254
41	13873
41	11656
41	43303
41	99122
41	56303
41	10030
41	35230
41	15302
41	49430
41	91166
41	1434
41	35147
41	62725
41	72075
41	58047
41	47738
41	84687
41	13828
41	29364
42	58656
42	44963
42	28958
42	92768
42	60365
42	30413
42	96839
42	62376
42	4762
42	4835
42	28452
42	55855
42	38288
42	70432
42	79803
42	91529
42	2702
42	73278
42	7972
42	92937
42	85689
42	49773
43	4266
43	17215
43	99591
43	38092
43	85944
43	12745
43	71253
43	84346
43	69313
43	90805
43	79374
43	92191
43	94204
43	56514
43	85347
43	80526
43	97601
43	13257
43	37708
43	740
43	33341
43	58852
44	85334
44	80329
44	40938
44	59353
44	44209
44	50918
44	64427
44	6111
44	5303
44	49691
44	49305
44	88416
44	60333
44	42031
44	85276
44	55586
44	90336
44	52493
44	95497
44	34867
44	22319
44	81006
45	1989
45	11079
45	71503
45	15436
45	32386
45	46561
45	44723
45	20091
45	67363
45	5119
45	72370
45	52656
45	97528
45	69661
45	25954
45	71481
45	27174
45	58955
45	11841
45	54466
45	97331
45	5024
46	56943
46	49381
46	83086
46	68961
46	17754
46	54481
46	80201
46	22051
46	86570
46	22428
46	28983
46	69827
46	21738
46	44754
46	6730
46	99436
46	59996
46	48847
46	3310
46	17764
46	75955
46	73743
47	9739
47	56673
47	16365
47	19583
47	86320
47	73717
47	22625
47	1719
47	12771
47	45101
47	59252
47	79363
47	27728
47	53655
47	56453
47	79097
47	92243
47	14657
47	22014
47	42994
47	7709
47	54152
48	81597
48	41814
48	64577
48	15889
48	49092
48	82421
48	5485
48	86813
48	7563
48	71516
48	51382
48	8234
48	89453
48	82512
48	66818
48	2061
48	1106
48	79620
48	25248
48	14235
48	43459
49	92780
49	36550
49	5462
49	75209
49	62088
49	24692
49	36309
49	51460
49	6741
49	23253
49	21916
49	98659
49	45203
49	74027
49	7093
49	73814
49	49869
49	152
49	58223
49	1357
49	59293
49	42008
50	28840
50	69496
50	22131
50	51375
50	1521
50	52046
50	74225
50	25299
50	78559
50	10564
50	66344
50	44601
50	78973
50	98520
50	36858
50	49495
50	79398
50	92882
50	83784
50	65280
50	67199
50	55906
51	92179
51	96339
51	39480
51	76565
51	52495
51	92623
51	15799
51	69782
51	33494
51	1889
51	95911
51	85737
51	1116
51	61383
51	40379
51	66341
51	31665
51	97223
51	2863
51	70832
51	22122
51	52199
52	79480
52	80682
52	49542
52	67172
52	26928
52	20802
52	57117
52	92865
52	48908
52	69140
52	72035
52	24336
52	28347
52	57993
52	46247
52	7639
52	23492
52	33693
52	82311
52	72288
52	25911
52	65220
53	38468
53	91027
53	39881
53	3089
53	87826
53	84831
53	50231
53	29497
53	59295
53	85347
53	81653
53	39211
53	52190
53	79649
53	87452
53	21477
53	33095
53	87073
53	15746
53	35817
53	26019
53	42194
54	98547
54	69750
54	40730
54	50918
54	27876
54	57868
54	44178
54	80623
54	89785
54	1892
54	13066
54	97894
54	93813
54	19543
54	75156
54	67346
54	5710
54	15697
54	71162
54	89657
54	506
54	15806
55	70389
55	43823
55	89288
55	6124
55	81517
55	62878
55	26508
55	62622
55	85649
55	71673
55	59276
55	46476
55	53883
55	88982
55	62843
55	81717
55	37569
55	87829
56	36262
56	14115
56	85637
56	16302
56	85328
56	54509
56	12327
56	38439
56	18523
56	8534
56	618
56	64761
56	84660
56	76749
56	54124
56	40941
56	72726
56	38873
56	44446
56	65940
56	36239
56	67013
57	83771
57	6291
57	83431
57	11158
57	23914
57	39366
57	69190
57	82339
57	78829
57	78579
57	54840
57	63357
57	22353
57	50931
57	37589
57	87730
57	8770
57	70887
57	23555
57	7620
57	93505
57	60319
58	69826
58	98569
58	34192
58	75651
58	53882
58	32967
58	57242
58	28341
58	35865
58	85257
58	26700
58	49790
58	66263
58	9648
58	16610
58	93772
58	89866
58	38526
58	80274
58	11040
58	51339
58	38037
59	88474
59	82650
59	50070
59	93298
59	34780
59	66559
59	67742
59	90085
59	26664
59	99158
59	21144
59	43724
59	1895
59	52841
59	62692
59	19279
59	88961
59	14373
59	2344
59	16358
59	88434
59	65653
60	86570
60	52002
60	75955
60	25037
60	16760
60	80201
60	8966
60	76740
60	17754
60	15387
60	3310
60	9512
60	93949
60	69827
60	34782
60	15506
60	99918
60	4721
60	38339
60	45852
60	83158
60	46849
61	98896
61	93437
61	21834
61	77492
61	45746
61	22957
61	16096
61	95256
61	36121
61	12214
61	19161
61	47234
61	34931
61	85922
61	59066
61	44038
61	94749
61	95129
61	20189
61	26239
61	71680
61	9155
62	19646
62	38384
62	57872
62	43459
62	8874
62	49092
62	51382
62	88758
62	81234
62	81755
62	86813
62	29849
62	3147
62	32350
62	25319
62	88110
62	82512
62	75107
62	16654
62	45485
62	3578
62	66723
63	15615
63	6049
63	2042
63	46888
63	6319
63	76532
63	77459
63	39411
63	38451
63	37808
63	75698
63	47282
63	79631
63	66325
63	2848
63	21077
63	16064
63	94605
63	42108
63	10730
63	53023
63	78417
64	81262
64	37134
64	40638
64	29493
64	70989
64	70943
64	23830
64	7028
64	1173
64	12676
64	93334
64	48019
64	15295
64	28478
64	44025
64	29822
64	97086
64	46961
64	42138
64	24411
64	9102
64	32482
65	98482
65	89990
65	2078
65	53641
65	42008
65	17534
65	49869
65	152
65	32442
65	24692
65	45203
65	66232
65	27061
65	25424
65	7093
65	17792
65	93415
65	29194
65	75209
65	7167
65	64967
65	43291
66	69496
66	88284
66	84868
66	7090
66	53255
66	20318
66	11635
66	44601
66	53183
66	66576
66	12041
66	87406
66	15310
66	84531
66	54240
66	46575
66	65280
66	81432
66	97314
66	92882
66	98520
66	45918
67	78119
67	39669
67	35569
67	25807
67	47080
67	45574
67	70753
67	60694
67	28715
67	9457
67	15894
67	72928
67	70361
67	60745
67	4087
67	83598
67	81374
67	42336
67	95817
67	47525
67	52450
67	43964
68	6529
68	36442
68	390
68	22072
68	5606
68	80874
68	85853
68	66707
68	68644
68	10808
68	4699
68	19652
68	4951
68	10562
68	15820
68	18513
68	26638
68	87777
68	73309
68	6524
69	64611
69	5331
69	506
69	27876
69	20993
69	20604
69	19543
69	60020
69	53302
69	44178
69	9700
69	94112
69	68231
69	97894
69	98547
69	63738
69	80623
69	14406
69	51308
69	46939
69	30328
69	30097
70	9081
70	90871
70	9221
70	4447
70	88846
70	58180
70	15472
70	71884
70	15041
70	4515
70	92456
70	38003
70	25326
70	81979
70	72128
70	70566
70	88221
70	41399
70	53949
70	72588
70	71030
70	93253
71	38439
71	70798
71	12327
71	40941
71	65940
71	57200
71	78277
71	10601
71	18523
71	38873
71	90496
71	83575
71	95472
71	44446
71	74898
71	80644
71	92883
71	93118
71	66683
71	96652
71	84660
71	13223
72	37943
72	39583
72	51214
72	61853
72	34121
72	61483
72	68778
72	53545
72	9250
72	85009
72	39750
72	8136
72	5766
72	33698
72	71954
72	9973
72	58241
72	10374
72	57739
72	63184
72	80280
72	15476
73	6291
73	23555
73	67864
73	39366
73	78579
73	81384
73	87730
73	50931
73	93505
73	83431
73	74352
73	52456
73	13610
73	5550
73	70847
73	44949
73	43123
73	42
73	95843
73	82751
73	47783
73	85317
74	69090
74	10583
74	11223
74	15145
74	91035
74	40725
74	71952
74	43944
74	98280
74	35675
74	33713
74	73082
74	35217
74	60343
74	81409
74	51757
74	86786
74	22258
74	20645
74	58138
74	46624
74	19812
75	82202
75	11040
75	34192
75	3503
75	98569
75	32967
75	57255
75	5242
75	79204
75	26700
75	4538
75	69826
75	28341
75	81537
75	66263
75	49790
75	54866
75	75651
75	80274
75	9741
75	51811
75	69227
76	86570
76	70724
76	7056
76	52002
76	7441
76	76740
76	38164
76	82336
76	39031
76	38906
76	46080
76	75955
76	7545
76	20979
76	577
76	34782
76	40185
76	60629
76	82525
76	45310
76	27005
76	54379
77	71680
77	22974
77	8277
77	77492
77	37610
77	21834
77	26239
77	65506
77	90655
77	16445
77	94749
77	71720
77	28805
77	45404
77	85922
77	21516
77	55526
77	82183
77	70067
77	39483
77	93437
77	9155
78	6948
78	58940
78	42945
78	39670
78	43459
78	47763
78	84663
78	34086
78	60811
78	3578
78	86813
78	55839
78	79975
78	69171
78	17583
78	93416
78	300
78	75118
78	96877
78	8601
78	35894
78	97832
79	2042
79	56360
79	15615
79	76532
79	23507
79	77459
79	94935
79	92981
79	81510
79	37808
79	63080
79	47282
79	66325
79	48323
79	2130
79	8451
79	77939
79	94605
79	86268
79	38969
79	78417
79	75977
80	81262
80	61906
80	92656
80	44813
80	70989
80	73769
80	29822
80	82971
80	1173
80	77346
80	69885
80	48019
80	83705
80	44025
80	78478
80	91386
80	99943
80	78197
80	78802
80	47384
80	36108
80	1406
81	69496
81	75144
81	84868
81	56205
81	41805
81	70829
81	82053
81	92848
81	90775
81	53579
81	45721
81	97290
81	21324
81	1211
81	63904
81	92882
81	53255
81	96660
81	10223
81	54240
81	91558
81	95498
82	82415
82	82190
82	3683
82	13513
82	56108
82	41288
82	12780
82	36975
82	79456
82	89933
82	77851
82	66051
82	87116
82	81010
82	28578
82	15853
82	20825
82	33683
82	87420
82	82907
82	87803
82	72502
83	31624
83	15860
83	73770
83	17442
83	11712
83	25462
83	17292
83	22636
83	32438
83	17727
83	19817
83	43460
83	85095
83	98385
83	85798
83	88328
83	41977
83	43310
83	33966
83	86843
83	65484
83	32612
84	439
84	18281
84	22201
84	42014
84	79871
84	89367
84	70034
84	87139
84	25807
84	47080
84	25161
84	70753
84	73507
84	90549
84	76869
84	7282
84	19215
84	13330
84	75309
84	91151
84	27462
84	72928
85	9317
85	48811
85	33632
85	49657
85	69088
85	65970
85	35585
85	11702
85	54948
85	67694
85	80609
85	92483
85	1959
85	4392
85	63158
85	49145
85	92440
85	77966
85	87288
85	45067
85	9442
85	68478
86	15746
86	25529
86	8805
86	10338
86	80056
86	42409
86	20173
86	69813
86	82312
86	44518
86	33095
86	26019
86	63780
86	65514
86	91855
86	37296
86	21974
86	81709
86	81023
86	59295
86	12844
86	92811
87	51617
87	50023
87	78856
87	66078
87	66610
87	57163
87	90482
87	8340
87	12687
87	71223
87	29764
87	10948
87	85966
87	72420
87	27720
87	49064
87	22295
87	51500
87	89259
87	8736
87	452
87	1974
88	66256
88	34121
88	34271
88	61483
88	5971
88	55225
88	2292
88	8136
88	9973
88	96191
88	63184
88	64138
88	33698
88	93539
88	11664
88	6103
88	93072
88	30065
88	48102
88	45615
88	24558
88	15476
89	6291
89	68158
89	76961
89	67864
89	92425
89	74352
89	42
89	27264
89	81384
89	71169
89	16586
89	85317
89	47783
89	52170
89	15756
89	32217
89	24259
89	17091
89	47145
89	10089
89	44453
89	55024
90	855
90	86786
90	867
90	25685
90	81303
90	28121
90	14074
90	18389
90	71464
90	46624
90	33017
90	84034
90	47266
90	34981
90	36583
90	92300
90	27099
90	96092
90	27897
90	90625
90	32023
90	17625
91	7056
91	52002
91	34782
91	82525
91	39031
91	75955
91	46080
91	76740
91	87810
91	38906
91	54379
91	17125
91	70724
91	76352
91	58585
91	89643
91	21480
91	13437
91	45310
91	96621
91	38164
91	86570
92	3284
92	88804
92	19802
92	20700
92	80720
92	55242
92	3125
92	31348
92	52425
92	89534
92	22594
92	1172
92	82222
92	14962
92	72803
92	76463
92	46885
92	90267
92	6520
92	3916
92	88639
92	8847
93	747
93	15923
93	53489
93	51334
93	79148
93	65214
93	98252
93	1618
93	87363
93	69887
93	22224
93	80104
93	43288
93	36467
93	77566
93	23529
93	58900
93	97048
93	52647
93	42198
93	4782
93	24782
94	79242
94	60014
94	32148
94	40750
94	75261
94	87249
94	98630
94	48377
94	16644
94	61986
94	10418
94	38014
94	17067
94	81306
94	32950
94	9775
94	7544
94	79071
94	73967
94	31841
94	37056
94	93894
95	9155
95	10947
95	21516
95	77492
95	21834
95	37610
95	53400
95	82183
95	90655
95	34289
95	26685
95	46630
95	63937
95	88346
95	62981
95	55526
95	57430
95	90033
95	25708
95	16445
95	69107
95	22136
96	22822
96	44896
96	15317
96	34086
96	10882
96	5132
96	9806
96	75574
96	98541
96	3578
96	8601
96	79975
96	60811
96	42021
96	93416
96	52816
96	84663
96	33839
96	87143
96	97255
96	58940
96	70505
97	81262
97	61906
97	95637
97	44813
97	1864
97	92656
97	69885
97	78670
97	21188
97	82971
97	36108
97	93850
97	52027
97	99498
97	1410
97	74113
97	30138
97	78197
97	23218
97	4081
97	5681
97	1406
98	95875
98	5300
98	11175
98	97727
98	34023
98	53115
98	14709
98	80419
98	60629
98	12682
98	34797
98	40979
98	73673
98	62214
98	39599
98	31011
98	50486
98	29660
98	89616
98	92379
98	37836
98	72738
99	69496
99	75144
99	63904
99	56205
99	53255
99	46575
99	32063
99	92848
99	61576
99	52254
99	5631
99	21324
99	76847
99	87807
99	48537
99	9921
99	12371
99	82053
99	47450
99	32657
99	70795
99	62196
100	9317
100	92483
100	56493
100	70032
100	68508
100	4392
100	63158
100	28651
100	35635
100	65970
100	22661
100	63252
100	87288
100	11702
100	63122
100	3441
100	45798
100	19936
100	5819
100	60181
100	57969
100	38721
101	58349
101	39089
101	90224
101	61299
101	80578
101	34403
101	987
101	31306
101	9022
101	12970
101	82150
101	15268
101	89577
101	12676
101	93628
101	59058
101	81323
101	3894
101	70798
101	61313
101	39055
101	941
102	70926
102	73008
102	32477
102	97894
102	92709
102	33226
102	99095
102	95816
102	55057
102	36812
102	46939
102	793
102	32732
102	14618
102	98547
102	52416
102	9700
102	14930
102	58469
102	30097
102	25619
102	57789
103	83945
103	11119
103	36059
103	96412
103	41691
103	28196
103	4270
103	82186
103	15857
103	47892
103	81929
103	30655
103	12327
103	89509
103	72837
103	92902
103	89353
103	5619
103	4101
103	77314
103	35342
103	82133
104	35661
104	34121
104	93072
104	77426
104	41116
104	55225
104	41843
104	12272
104	64138
104	12917
104	63184
104	83060
104	48317
104	65688
104	27606
104	6103
104	24131
104	19353
104	48720
104	10351
104	24558
104	98864
105	50189
105	38654
105	32623
105	67185
105	15585
105	16586
105	64450
105	15756
105	55024
105	5537
105	47998
105	68158
105	39332
105	76961
105	47431
105	3917
105	55272
105	66765
105	78976
105	4783
105	9067
105	33786
106	855
106	62756
106	21555
106	94783
106	40725
106	53257
106	867
106	5616
106	61271
106	92300
106	42100
106	27099
106	49889
106	44727
106	62533
106	17625
106	46231
106	35675
106	47496
106	20306
106	97042
106	95542
107	7056
107	52002
107	18102
107	70724
107	59934
107	58585
107	577
107	86293
107	84905
107	38906
107	4354
107	39644
107	34746
107	40151
107	82525
107	46080
107	77430
107	66524
107	93168
107	53202
107	66939
107	49805
108	3284
108	53019
108	7046
108	66746
108	59856
108	1172
108	6520
108	20700
108	72803
108	26899
108	89534
108	67000
108	22594
108	1235
108	5257
108	76463
108	4189
108	12058
108	94330
108	92893
108	66734
108	79047
109	47391
109	77734
109	42198
109	23529
109	98099
109	15923
109	95834
109	69887
109	80104
109	52787
109	87363
109	83441
109	61074
109	33539
109	98252
109	6141
109	22224
109	4782
109	39340
109	24618
109	42080
109	27288
110	74455
110	56457
110	15317
110	34887
110	43761
110	52816
110	22841
110	75574
110	8601
110	34802
110	9806
110	22822
110	25979
110	44896
110	64663
110	34233
110	5132
110	70457
110	1287
110	49523
110	33839
110	97255
111	3644
111	15235
111	43085
111	90417
111	53136
111	94477
111	8286
111	98706
111	57925
111	39420
111	20709
111	86721
111	93859
111	5248
111	59228
111	77479
111	41229
111	17245
111	3840
111	94089
111	95105
111	46980
112	5681
112	34606
112	61906
112	93850
112	95637
112	92656
112	82516
112	88739
112	21188
112	74113
112	30138
112	36108
112	55221
112	99498
112	35206
112	82971
112	49366
112	52027
112	82931
112	7203
112	32722
112	64569
113	73673
113	8972
113	1013
113	72738
113	42540
113	68170
113	11488
113	18770
113	89616
113	68792
113	35433
113	27425
113	46187
113	91195
113	77332
113	50486
113	73715
113	59807
113	62214
113	91752
113	45085
113	97727
114	69496
114	76847
114	64553
114	75144
114	48537
114	5631
114	12371
114	91914
114	85684
114	48001
114	37767
114	66980
114	13602
114	35938
114	69898
114	93728
114	29553
114	28249
114	92848
114	55734
114	65845
114	4130
115	36838
115	48502
115	67273
115	6709
115	61086
115	480
115	64788
115	87203
115	60695
115	11641
115	50323
115	40283
115	40761
115	6724
115	59059
115	45281
115	52780
115	70204
115	88081
115	27004
115	3861
115	74112
116	44487
116	67001
116	91257
116	53884
116	44233
116	70918
116	13304
116	74248
116	39642
116	3493
116	60225
116	67663
116	74747
116	64664
116	79162
116	44642
116	36538
116	68398
116	24730
116	58433
116	9642
116	60146
117	9317
117	60181
117	4392
117	36991
117	76618
117	28651
117	90524
117	22661
117	60231
117	40669
117	38721
117	63252
117	99442
117	24268
117	57969
117	19936
117	53800
117	44798
117	83456
117	87023
117	79597
117	91040
118	61200
118	50021
118	50137
118	80578
118	42046
118	48822
118	5221
118	80285
118	49138
118	39055
118	9022
118	93882
118	45285
118	82150
118	59058
118	3159
118	8045
118	58423
118	53638
118	15268
118	3894
118	34577
119	70926
119	71588
119	93161
119	20138
119	81281
119	52416
119	48137
119	57315
119	55057
119	20997
119	73866
119	11454
119	53124
119	69289
119	70292
119	42555
119	836
119	99095
119	1529
119	95816
119	98546
119	95773
120	53140
120	11119
120	41231
120	34358
120	41691
120	30744
120	82186
120	63431
120	15857
120	47892
120	4270
120	83945
120	18360
120	36059
120	63224
120	89353
120	3368
120	22700
120	77314
120	98414
120	99710
120	61834
121	35661
121	28162
121	93072
121	72864
121	77426
121	11099
121	12917
121	12272
121	64138
121	86276
121	32446
121	60896
121	5324
121	19519
121	83141
121	86015
121	55399
121	50033
121	71648
121	48733
121	85955
121	14080
122	92631
122	23037
122	98745
122	23879
122	77985
122	74479
122	67478
122	47829
122	89771
122	94646
122	67309
122	69901
122	47589
122	43522
122	43168
122	42364
122	13390
122	59854
122	69323
122	69996
122	77729
122	62963
123	39749
123	59934
123	2965
123	25829
123	14923
123	15663
123	77430
123	4354
123	53202
123	38906
123	85778
123	47010
123	97113
123	87388
123	17395
123	27277
123	34222
123	65181
123	49805
123	3810
123	72683
123	6015
124	66734
124	53019
124	19802
124	30493
124	92893
124	59856
124	2372
124	63835
124	26899
124	22594
124	6520
124	47776
124	18674
124	1172
124	66746
124	45469
124	15241
124	28376
124	72803
124	27243
124	99127
124	92968
125	15216
125	49133
125	95896
125	22118
125	88857
125	25708
125	37315
125	61272
125	43628
125	34289
125	31552
125	99091
125	21149
125	4640
125	43520
125	48978
125	46923
125	33536
125	94047
125	6647
125	90487
125	17536
126	8268
126	86
126	60582
126	54377
126	33258
126	2166
126	83098
126	16270
126	49544
126	10096
126	24464
126	58367
126	4639
126	98965
126	70115
126	86181
126	65859
126	87801
126	55432
126	10061
126	28429
126	56225
127	74455
127	79568
127	40921
127	62668
127	49952
127	52816
127	88728
127	22841
127	8601
127	34802
127	34233
127	25979
127	43486
127	22176
127	34887
127	63494
127	43761
127	70457
127	77223
127	11917
127	52978
127	27328
128	9393
128	8449
128	92635
128	87631
128	78005
128	94998
128	95383
128	62232
128	95869
128	77834
128	22729
128	10922
128	14437
128	37385
128	86314
128	60216
128	75509
128	43630
128	91215
128	39275
128	18748
128	66373
129	73673
129	42540
129	68170
129	56668
129	53189
129	28851
129	77413
129	45085
129	3206
129	72033
129	119
129	48831
129	67671
129	62214
129	91195
129	77530
129	68967
129	68792
129	86117
129	92154
129	5329
129	63857
130	66980
130	80210
130	64553
130	36154
130	42664
130	69898
130	23385
130	96873
130	55734
130	56971
130	91914
130	62196
130	96177
130	38555
130	85808
130	5631
130	13602
130	32657
130	7812
130	64207
130	48001
130	18898
131	34408
131	93664
131	20578
131	48556
131	99082
131	93911
131	45308
131	55928
131	89897
131	37859
131	85379
131	38795
131	75161
131	69368
131	45711
131	15207
131	50217
131	98667
131	99251
132	15677
132	30953
132	38349
132	76522
132	80565
132	39336
132	19550
132	64457
132	83669
132	96979
132	3607
132	24515
132	32760
132	20506
132	38889
132	53754
132	96893
132	17992
132	17652
132	49357
132	84160
132	51451
133	4931
133	35798
133	53044
133	61942
133	98936
133	65622
133	2403
133	75663
133	51434
133	41601
133	9236
133	52148
133	37721
133	3154
133	26224
133	50489
133	21011
133	76074
133	80696
133	15758
133	26945
133	73129
134	99794
134	79597
134	76618
134	70748
134	17002
134	52906
134	70408
134	90524
134	28651
134	97724
134	33189
134	79846
134	9317
134	50044
134	60181
134	2102
134	72049
134	19936
134	43733
134	59828
134	98262
134	53800
135	43209
135	84013
135	15529
135	29454
135	82719
135	22223
135	86931
135	61735
135	73517
135	37575
135	61494
135	12397
135	20172
135	2986
135	71234
135	63446
135	37477
135	746
135	5872
135	48546
135	71589
135	31050
136	53140
136	47978
136	83747
136	63224
136	83931
136	50162
136	81929
136	47892
136	99710
136	40429
136	93811
136	51832
136	90366
136	58801
136	48169
136	30744
136	51410
136	95376
136	2662
136	82186
136	8424
136	81455
137	14080
137	28162
137	93072
137	72864
137	77426
137	11099
137	69695
137	12272
137	64138
137	86276
137	63982
137	60896
137	72441
137	62529
137	83141
137	86015
137	12863
137	50033
137	9958
137	48733
137	89031
137	57908
138	53390
138	30957
138	33365
138	26050
138	56518
138	79103
138	37370
138	16804
138	64046
138	82218
138	4739
138	25276
138	35082
138	94783
138	49585
138	16060
138	63462
138	68438
138	39768
138	90840
138	81341
138	82033
139	24116
139	14851
139	41457
139	57113
139	39161
139	6541
139	84569
139	97283
139	68903
139	82355
139	22858
139	31090
139	71410
139	41896
139	90391
139	69601
139	64841
139	19334
139	33066
139	37148
139	68603
139	29734
140	6015
140	87744
140	89772
140	72683
140	2965
140	81415
140	77430
140	50358
140	73846
140	85778
140	65181
140	60490
140	89117
140	48382
140	6277
140	15663
140	7188
140	41064
140	1779
140	49805
140	89519
140	60866
141	74765
141	97295
141	1172
141	75999
141	35917
141	59856
141	74402
141	63835
141	95083
141	80628
141	4554
141	30493
141	90799
141	68155
141	66322
141	99127
141	45469
141	76230
141	96963
141	77670
141	62720
141	66734
142	80380
142	51910
142	78049
142	3546
142	95834
142	23733
142	57208
142	39340
142	34039
142	34664
142	54736
142	37201
142	4458
142	73006
142	36374
142	27772
142	27288
142	28298
142	46424
142	67855
142	61074
142	2104
143	79032
143	55761
143	18468
143	72348
143	88482
143	34021
143	24093
143	8298
143	62195
143	87788
143	91963
143	57266
143	73521
143	27040
143	53970
143	46189
143	73193
143	12102
143	4924
143	57624
143	54611
143	1760
144	46307
144	93412
144	47461
144	67450
144	71319
144	28084
144	40069
144	83389
144	54786
144	39155
144	58000
144	13619
144	11430
144	14414
144	28638
144	16092
144	52149
144	50623
144	19426
144	32958
144	87822
144	42054
145	48831
145	39619
145	68170
145	12030
145	72137
145	42540
145	91195
145	93703
145	74017
145	62214
145	119
145	73673
145	31389
145	83005
145	97066
145	68792
145	58264
145	44349
145	32265
145	92154
145	29600
145	65172
146	76357
146	1582
146	65100
146	29733
146	74745
146	89311
146	43188
146	12372
146	84295
146	25337
146	48712
146	31830
146	16991
146	50564
146	63266
146	89554
146	48827
146	35622
146	36
146	45370
146	89818
146	44945
147	96371
147	6667
147	62487
147	89521
147	17846
147	95634
147	57366
147	90440
147	48883
147	39234
147	7479
147	29548
147	97548
147	65840
147	45208
147	21597
147	92867
147	20188
147	58729
147	28931
147	26520
147	69383
148	30434
148	88006
148	66125
148	63058
148	87058
148	36988
148	93687
148	68584
148	22480
148	47050
148	21810
148	72460
148	62568
148	98422
148	78929
148	14033
148	78336
148	27901
148	22762
148	87723
148	54370
148	24731
149	43209
149	96792
149	37942
149	29454
149	90911
149	37575
149	86931
149	52989
149	73517
149	39318
149	94413
149	12397
149	82719
149	88425
149	2323
149	71589
149	16755
149	33030
149	20172
149	12173
149	61494
149	30429
150	53140
150	50198
150	32274
150	34358
150	83931
150	46047
150	81929
150	99710
150	36986
150	47892
150	61660
150	51832
150	62134
150	13110
150	32102
150	35067
150	85474
150	11707
150	82387
150	85775
150	19953
150	85729
151	14080
151	69695
151	48686
151	66174
151	72864
151	28162
151	89257
151	44313
151	48733
151	66405
151	79006
151	60896
151	72441
151	92173
151	15681
151	41102
151	35602
151	89218
151	25938
151	48661
151	7141
151	44327
152	84648
152	47694
152	262
152	2400
152	20553
152	29556
152	46434
152	26214
152	28747
152	67954
152	88088
152	27514
152	62762
152	19642
152	60845
152	52104
152	23309
152	80725
152	74389
152	43672
152	18421
152	20595
153	49497
153	99200
153	44782
153	68390
153	69624
153	1597
153	92929
153	57731
153	87506
153	49087
153	67711
153	71914
153	88955
153	27837
153	38620
153	739
153	71906
153	20897
153	28534
153	56615
153	11236
153	10863
154	44317
154	66254
154	45593
154	61157
154	25276
154	99593
154	3905
154	21190
154	4739
154	35082
154	30336
154	23168
154	66065
154	26640
154	6976
154	34830
154	45194
154	1736
154	80376
154	54098
154	62351
154	12477
155	62318
155	47233
155	61365
155	49343
155	92720
155	31109
155	68078
155	3451
155	52271
155	25569
155	90221
155	15636
155	73149
155	80182
155	5699
155	27925
155	75962
155	99989
155	82174
155	82507
155	40884
155	28170
156	6015
156	52658
156	69644
156	54171
156	22554
156	12950
156	4940
156	37483
156	84320
156	85778
156	89519
156	43781
156	48382
156	99390
156	70909
156	67433
156	99975
156	34545
156	23407
156	86942
156	53581
156	60866
157	41870
157	12738
157	3719
157	34605
157	86043
157	90883
157	56255
157	54040
157	19199
157	65887
157	48925
157	50374
157	54760
157	27315
157	8939
157	83674
157	16067
157	99991
157	74565
157	67442
157	32988
157	80046
158	64266
158	56063
158	99164
158	42012
158	12183
158	36123
158	99185
158	34326
158	86777
158	45243
158	13770
158	70353
158	17566
158	53099
158	2094
158	88526
158	77765
158	15153
158	5262
158	72757
158	67438
158	53278
159	47243
159	76170
159	77051
159	64960
159	85841
159	36227
159	81360
159	64031
159	64311
159	36867
159	90846
159	4692
159	76892
159	33083
159	61698
159	88492
159	60654
159	14915
159	70253
159	98081
159	25070
159	29913
160	48831
160	83005
160	3775
160	5902
160	21248
160	84137
160	78456
160	99788
160	88467
160	12030
160	34868
160	37637
160	39505
160	93788
160	17293
160	44349
160	80851
160	57787
160	16875
160	29600
160	91717
160	76506
161	7985
161	86324
161	4060
161	4466
161	84173
161	55869
161	8713
161	3980
161	64532
161	10248
161	26316
161	64464
161	67584
161	46352
161	42842
161	25743
161	69029
161	21068
161	49253
161	19851
161	52419
161	50233
162	35622
162	3270
162	60031
162	37179
162	31830
162	89311
162	46710
162	12372
162	1582
162	25337
162	48712
162	63266
162	16991
162	55099
162	23888
162	89554
162	48827
162	48111
162	60714
162	45370
162	91947
162	82670
163	28179
163	32834
163	32373
163	76522
163	93346
163	72529
163	91524
163	23639
163	94008
163	96979
163	50099
163	48921
163	3944
163	67187
163	85374
163	44786
163	94706
163	62666
163	42136
163	49357
163	7978
163	28828
164	6667
164	60895
164	56499
164	89521
164	42824
164	95634
164	18317
164	97548
164	48883
164	32819
164	37521
164	29548
164	15890
164	99151
164	69383
164	21597
164	92867
164	3652
164	67962
164	22126
164	9868
164	19443
165	5695
165	88006
165	14033
165	98422
165	54370
165	93612
165	58552
165	68584
165	22480
165	57616
165	73968
165	32668
165	53235
165	23439
165	16479
165	35089
165	48230
165	91562
165	96391
165	3406
165	57585
165	94977
166	84380
166	26973
166	29981
166	57837
166	90350
166	70869
166	40352
166	3571
166	99707
166	39440
166	28881
166	12922
166	23912
166	15195
166	87767
166	40419
166	50273
166	58423
166	78126
166	38692
166	26030
166	44005
167	43209
167	59590
167	60570
167	29454
167	52124
167	88425
167	69553
167	86931
167	891
167	61240
167	3989
167	16755
167	65696
167	91705
167	55852
167	52989
167	91463
167	6774
167	37942
167	12765
167	35750
167	39318
168	25714
168	32712
168	10069
168	82486
168	71287
168	66055
168	94864
168	44105
168	47488
168	12467
168	25130
168	36542
168	32146
168	50864
168	1949
168	23179
168	74931
168	43535
168	78107
168	16979
168	72733
168	99636
169	14080
169	69695
169	55894
169	47205
169	68969
169	41102
169	64134
169	3391
169	52461
169	15681
169	59574
169	66174
169	11877
169	34993
169	20874
169	44313
169	35602
169	71765
169	85977
169	95747
169	39513
169	96776
170	73371
170	88535
170	21849
170	97960
170	73411
170	12808
170	40338
170	48327
170	68346
170	59774
170	45774
170	71313
170	70419
170	42885
170	75422
170	63564
170	40564
170	16403
170	13314
170	99212
170	15801
170	77356
171	66254
171	45593
171	99392
171	61157
171	10969
171	78111
171	25276
171	3905
171	99593
171	80404
171	35082
171	79724
171	46907
171	6976
171	80376
171	15637
171	33159
171	54098
171	29420
171	2464
171	62351
171	26142
172	62318
172	77455
172	61365
172	32042
172	92720
172	31109
172	99989
172	3451
172	52271
172	43037
172	90221
172	96650
172	96142
172	82507
172	6318
172	84133
172	41829
172	64028
172	5699
172	13147
172	7810
172	29893
173	84816
173	73390
173	7663
173	86900
173	88903
173	26401
173	53789
173	47829
173	6736
173	94036
173	25456
173	77440
173	43941
173	53153
173	79995
173	47416
173	17433
173	87975
173	52742
173	7477
173	88070
173	38187
174	60866
174	65003
174	69644
174	45267
174	22554
174	83096
174	6098
174	78605
174	20664
174	37483
174	39132
174	49168
174	71619
174	70038
174	35736
174	12950
174	66932
174	99975
174	56757
174	86942
174	89519
174	43781
175	95667
175	73034
175	96632
175	59682
175	66008
175	44016
175	11469
175	32771
175	58080
175	34300
175	59315
175	17774
175	93565
175	2805
175	72682
175	18610
175	33634
175	41427
175	52069
175	39692
175	93395
175	11668
176	5974
176	93218
176	15628
176	33323
176	95834
176	26922
176	31736
176	86201
176	43905
176	64288
176	56491
176	2230
176	57208
176	74243
176	81864
176	12252
176	12971
176	36374
176	95822
176	71032
176	3126
176	10055
177	10247
177	58761
177	53399
177	28511
177	55121
177	62199
177	40071
177	19209
177	95927
177	59697
177	12019
177	95371
177	26352
177	20020
177	49134
177	54028
177	61860
177	69858
177	81007
177	60697
177	41194
177	51677
178	45636
178	98480
178	58500
178	98609
178	47601
178	55381
178	6708
178	38399
178	84407
178	12423
178	11306
178	86679
178	48156
178	41807
178	49970
178	21488
178	46831
178	58071
178	4162
178	29001
179	79390
179	70102
179	4882
179	49962
179	40179
179	19836
179	50128
179	65224
179	68542
179	31450
179	83210
179	47197
179	34569
179	52968
179	72479
179	2675
179	59016
179	68823
179	34141
179	28235
179	34594
179	20640
180	41870
180	69834
180	12738
180	3719
180	34605
180	90883
180	81366
180	54040
180	5511
180	8939
180	32542
180	79617
180	14107
180	76592
180	12716
180	13150
180	16067
180	99991
180	74565
180	6095
180	17626
180	98948
181	6835
181	62087
181	72685
181	62128
181	71750
181	33765
181	17413
181	26834
181	84123
181	55438
181	54224
181	30605
181	88933
181	29948
181	10770
181	75470
181	91620
181	42459
181	26353
181	6989
181	80606
181	88196
182	67438
182	70353
182	53099
182	42012
182	77109
182	45821
182	99185
182	34326
182	86777
182	53791
182	60461
182	34354
182	2094
182	65801
182	46674
182	69257
182	17566
182	53311
182	51494
182	795
182	86176
182	55970
183	48831
183	42920
183	29143
183	3775
183	30672
183	21248
183	99788
183	73911
183	88467
183	72980
183	6193
183	76506
183	75736
183	93788
183	44349
183	66365
183	31072
183	46574
183	16875
183	91717
183	89106
183	56533
184	21692
184	71779
184	75182
184	15273
184	68738
184	90628
184	20299
184	49203
184	97692
184	88607
184	90719
184	88598
184	39423
184	65991
184	8051
184	33410
184	61662
184	76079
184	32314
184	51432
184	79632
184	55917
185	14752
185	98380
185	35886
185	39611
185	80000
185	84240
185	38027
185	88108
185	50194
185	23450
185	30806
185	39675
185	53388
185	15562
185	98571
185	21395
185	81343
185	72373
185	69712
185	44600
185	69864
185	46351
186	55794
186	53798
186	40771
186	99050
186	52771
186	62565
186	5529
186	85997
186	96985
186	32829
186	76882
186	76981
186	65462
186	13942
186	39792
186	62599
186	4514
186	50213
186	59982
186	5291
186	36137
186	796
187	13103
187	32834
187	60966
187	56412
187	85374
187	72529
187	16659
187	23639
187	23072
187	96979
187	50099
187	51887
187	39268
187	64384
187	93346
187	55653
187	96784
187	12095
187	42136
187	94008
187	7978
187	79702
188	50717
188	17208
188	15890
188	88971
188	43189
188	51539
188	46254
188	2493
188	48883
188	1165
188	57931
188	22126
188	40684
188	98924
188	91411
188	21597
188	92867
188	69383
188	18317
188	3652
188	71920
188	76784
189	5695
189	66125
189	19146
189	91562
189	72942
189	11356
189	46604
189	68584
189	27545
189	11027
189	96391
189	26253
189	53843
189	12472
189	22480
189	57616
189	53126
189	56094
189	15973
189	85827
189	65495
189	85003
190	32342
190	49099
190	66593
190	56334
190	47456
190	18580
190	93680
190	64968
190	18718
190	13514
190	3282
190	27460
190	5530
190	10493
190	35273
190	5562
190	15023
190	58072
190	12978
190	116
190	90721
190	5387
191	84380
191	96996
191	19020
191	40490
191	35214
191	22433
191	3571
191	89298
191	37218
191	92317
191	65283
191	25980
191	14310
191	42410
191	24553
191	70703
191	86323
191	57343
191	39440
191	99707
191	44005
191	23912
192	7171
192	79689
192	48686
192	27251
192	31123
192	29426
192	89975
192	52461
192	89949
192	95747
192	59574
192	36307
192	40743
192	79344
192	45695
192	17092
192	39771
192	49502
192	25464
192	68969
192	85181
192	84364
193	76922
193	75249
193	96969
193	84644
193	17336
193	85024
193	43672
193	67521
193	68408
193	10281
193	83693
193	14305
193	74361
193	36045
193	707
193	46658
193	27514
193	56193
193	40780
193	28747
193	24680
193	84659
194	33690
194	88535
194	12743
194	97960
194	52965
194	58877
194	40338
194	16403
194	8861
194	59774
194	45774
194	68346
194	85018
194	42885
194	15505
194	63564
194	65733
194	82715
194	97535
194	80405
194	93051
194	15801
195	83449
195	22408
195	60363
195	45025
195	62815
195	80376
195	95267
195	61630
195	22755
195	80404
195	2464
195	70033
195	69165
195	49676
195	24755
195	46907
195	12666
195	15637
195	79080
195	98697
195	65092
195	64307
196	84816
196	73390
196	8623
196	39297
196	88903
196	26401
196	71806
196	97414
196	6736
196	13042
196	25456
196	38187
196	99499
196	5723
196	43888
196	47038
196	87975
196	24703
196	93848
196	47067
196	95299
196	92384
197	43781
197	33125
197	69644
197	12950
197	35736
197	83096
197	60969
197	19190
197	90635
197	37483
197	30573
197	34958
197	79755
197	5820
197	76896
197	6573
197	90842
197	78605
197	50408
197	12049
197	10596
197	6015
198	94024
198	5061
198	86608
198	28606
198	25752
198	73764
198	99064
198	9476
198	91932
198	32755
198	76141
198	32447
198	62546
198	7363
198	48970
198	33225
198	84561
198	25143
198	19526
198	8726
198	33846
198	52146
199	9660
199	97018
199	78960
199	7554
199	35196
199	15173
199	73303
199	61972
199	92139
199	27353
199	5935
199	82297
199	21914
199	67430
199	73226
199	8567
199	50657
199	25508
199	90988
199	13395
199	27647
199	33784
200	6115
200	46140
200	94731
200	40610
200	62631
200	92595
200	49069
200	21213
200	77330
200	36502
200	56788
200	53824
200	48513
200	7140
200	445
200	17302
200	58408
200	60480
200	92292
200	98689
200	4488
200	83507
201	20640
201	23718
201	59016
201	68542
201	29522
201	49962
201	2675
201	34141
201	65174
201	36651
201	19351
201	70102
201	81883
201	87821
201	49130
201	53735
201	76340
201	78807
201	38921
201	18335
201	8967
201	60826
202	51570
202	69834
202	29650
202	12738
202	27495
202	3719
202	94723
202	52595
202	643
202	8939
202	80821
202	79617
202	5511
202	76592
202	93959
202	12716
202	31235
202	99991
202	22982
202	88945
202	51538
202	87726
203	71520
203	65801
203	77817
203	51494
203	4063
203	45821
203	67142
203	99704
203	52793
203	88653
203	6745
203	795
203	56500
203	15144
203	26969
203	32610
203	13416
203	21159
203	48639
203	97362
203	81476
203	12206
204	20424
204	20549
204	8949
204	62944
204	15649
204	10707
204	97678
204	37600
204	34556
204	54079
204	88871
204	32244
204	56076
204	76810
204	72587
204	29742
204	685
204	22174
204	57174
204	33838
204	34985
204	42180
205	56533
205	29143
205	3775
205	30672
205	99684
205	99788
205	24028
205	73911
205	13638
205	49669
205	55733
205	50344
205	32608
205	69913
205	93788
205	66365
205	81402
205	46574
205	45432
205	91717
205	35253
205	57440
206	96913
206	47178
206	28996
206	38416
206	83744
206	10537
206	19791
206	3454
206	26316
206	62984
206	22941
206	43570
206	59792
206	56743
206	85837
206	67053
206	89412
206	63828
206	93110
206	83083
206	10248
206	66199
207	87191
207	92676
207	40516
207	95808
207	7753
207	40453
207	37917
207	99850
207	32922
207	4834
207	87575
207	37638
207	32719
207	74260
207	13902
207	11961
207	21024
207	43398
207	29930
207	3975
207	40996
207	79497
208	55794
208	53798
208	40771
208	62565
208	98708
208	99050
208	84808
208	32829
208	23905
208	62599
208	88012
208	4514
208	92698
208	96985
208	19672
208	99479
208	74529
208	76981
208	76882
208	28922
208	40633
208	42530
209	47269
209	13699
209	60644
209	77194
209	20267
209	56811
209	16678
209	73704
209	29440
209	53152
209	97522
209	3297
209	84056
209	69529
209	3360
209	37560
209	34547
209	55219
209	38392
209	74570
209	18120
209	82332
210	50717
210	31117
210	48883
210	146
210	22126
210	2493
210	71521
210	83573
210	39326
210	1165
210	57931
210	71920
210	71979
210	7710
210	40684
210	98924
210	86899
210	59285
210	39546
210	3652
210	17582
210	52039
211	98161
211	37038
211	22344
211	63783
211	31048
211	81444
211	97302
211	29698
211	31762
211	10440
211	94871
211	34980
211	94216
211	52794
211	48881
211	3000
211	88661
211	87641
211	77856
211	7955
211	61802
211	37242
212	85003
212	5434
212	64688
212	91562
212	53843
212	11356
212	46604
212	8096
212	65888
212	78666
212	42726
212	51002
212	36038
212	12472
212	39517
212	31710
212	56094
212	47824
212	97239
212	15973
212	89287
212	5695
213	77268
213	43950
213	65387
213	45849
213	68971
213	83876
213	19309
213	46375
213	51349
213	99813
213	13141
213	70602
213	66410
213	74032
213	87197
213	95664
213	64475
213	99042
213	50938
213	53955
213	53803
213	18924
214	32342
214	64968
214	66593
214	4915
214	18580
214	93918
214	34497
214	33328
214	27906
214	86826
214	3282
214	27460
214	48718
214	5562
214	51110
214	90721
214	12978
214	10906
214	10855
214	86677
214	16126
214	8071
215	63214
215	72141
215	96996
215	42410
215	91970
215	19020
215	32414
215	93792
215	12940
215	12398
215	70569
215	95106
215	44005
215	86323
215	31693
215	91175
215	2901
215	14296
215	18314
215	74307
215	6498
215	98382
216	73100
216	86817
216	48167
216	29429
216	89543
216	57952
216	68463
216	38492
216	94995
216	36582
216	37351
216	22385
216	77490
216	3963
216	72094
216	66014
216	19175
216	83805
216	97584
216	57189
216	18562
216	489
217	7171
217	79689
217	67713
217	27251
217	66165
217	36201
217	89975
217	49502
217	4572
217	79344
217	59574
217	71616
217	65532
217	59388
217	23204
217	45408
217	91180
217	93701
217	95392
217	27194
217	96946
217	84364
218	15637
218	22408
218	7031
218	14841
218	6684
218	10969
218	95267
218	35873
218	53936
218	80404
218	64003
218	34056
218	23349
218	49676
218	31161
218	46907
218	82949
218	80379
218	79080
218	14628
218	30977
218	15632
219	29893
219	22801
219	57468
219	46006
219	77198
219	69681
219	76884
219	67942
219	16938
219	52446
219	6378
219	11735
219	7284
219	79953
219	68014
219	67426
219	67358
219	57682
219	16277
219	46897
219	80487
219	91339
220	531
220	73390
220	43307
220	5723
220	51650
220	35636
220	95299
220	8623
220	28230
220	97414
220	25456
220	47067
220	99499
220	47038
220	11791
220	39297
220	37431
220	33618
220	3300
220	72937
220	69659
220	92384
221	31850
221	26340
221	88506
221	32466
221	76896
221	90842
221	66554
221	10596
221	90635
221	12049
221	61251
221	12036
221	62375
221	56505
221	60969
221	68671
221	52379
221	78793
221	61247
221	69952
221	6573
221	73607
222	17774
222	84420
222	56577
222	31657
222	31884
222	44016
222	77989
222	12458
222	58080
222	59402
222	41084
222	79721
222	81131
222	8703
222	94752
222	95667
222	53341
222	36769
222	19849
222	64478
222	3377
222	93402
223	31928
223	70177
223	14496
223	43980
223	39384
223	31126
223	53398
223	31825
223	43732
223	49600
223	2405
223	65731
223	41062
223	10890
223	92695
223	82012
223	96992
223	13552
223	69504
223	75417
223	33086
223	7687
224	62978
224	65985
224	59912
224	74237
224	50080
224	78926
224	2273
224	13444
224	35501
224	27437
224	1259
224	16382
224	64783
224	18941
224	49136
224	73174
224	87653
224	73643
224	37790
224	48788
224	81990
224	39680
225	76459
225	20237
225	40265
225	73737
225	57995
225	20647
225	8239
225	52500
225	16313
225	71260
225	85306
225	17800
225	82871
225	78227
225	28182
225	58445
225	65434
225	99987
225	71732
225	48690
225	22231
225	14432
226	42749
226	41175
226	51328
226	11562
226	31758
226	17383
226	54444
226	62193
226	89810
226	73679
226	57839
226	62807
226	53055
226	47911
226	10496
226	7223
226	1224
226	83361
226	26446
226	41648
226	72591
226	97395
227	20640
227	23718
227	67307
227	17303
227	55650
227	49962
227	2675
227	19351
227	18335
227	36651
227	38921
227	96960
227	81883
227	68510
227	10265
227	27404
227	34450
227	78807
227	6127
227	76340
227	81
227	13285
228	57440
228	42920
228	29143
228	35719
228	67143
228	47366
228	43222
228	73911
228	13638
228	67585
228	32608
228	61854
228	75545
228	13438
228	78756
228	49269
228	38434
228	25410
228	76544
228	35253
228	81402
228	88002
229	58282
229	37630
229	92391
229	72919
229	73794
229	50869
229	48431
229	19670
229	76874
229	32830
229	47334
229	11241
229	88192
229	52936
229	3942
229	53103
229	15631
229	77764
229	84043
229	42249
229	29008
229	30771
230	67839
230	24199
230	69817
230	8289
230	15882
230	4391
230	96122
230	95491
230	42603
230	94106
230	72379
230	64796
230	28854
230	66543
230	56580
230	52963
230	51629
230	90888
230	98535
230	61238
230	87036
230	57771
231	71173
231	94011
231	99719
231	42321
231	23176
231	19537
231	1137
231	83453
231	58563
231	30739
231	49988
231	44978
231	25437
231	69340
231	34184
231	40531
231	54322
231	67274
231	42807
231	78546
231	86528
231	63813
232	85003
232	53843
232	8096
232	5434
232	42726
232	64688
232	17223
232	78666
232	10580
232	10435
232	16627
232	51002
232	39265
232	34150
232	46094
232	49470
232	76645
232	39646
232	95626
232	9546
232	56270
232	18873
233	95438
233	43950
233	35322
233	99575
233	68971
233	83876
233	66410
233	43076
233	76411
233	47850
233	50938
233	86017
233	65387
233	51349
233	74032
233	95664
233	90303
233	15222
233	93046
233	55097
233	20285
233	50333
234	32342
234	64968
234	56334
234	86826
234	18580
234	16126
234	86677
234	48718
234	27906
234	10906
234	77250
234	99207
234	15788
234	35793
234	34497
234	90721
234	5885
234	10165
234	45890
234	6372
234	10577
234	77395
235	63214
235	31693
235	80363
235	75527
235	59110
235	40929
235	46166
235	90670
235	12940
235	84197
235	81270
235	76590
235	98382
235	82189
235	61508
235	44411
235	35246
235	10514
235	18314
235	61411
235	6498
235	49442
236	83613
236	39219
236	31156
236	22289
236	75066
236	23360
236	26709
236	63692
236	2017
236	21234
236	75272
236	41130
236	59805
236	71492
236	67329
236	92339
236	26281
236	60456
236	27804
236	81063
236	46228
236	94051
237	95570
237	23285
237	56780
237	36777
237	52938
237	35056
237	27017
237	90097
237	91477
237	11032
237	17799
237	16899
237	96771
237	77154
237	99834
237	16918
237	234
237	53430
237	27206
237	50458
237	17103
237	42685
238	43736
238	28361
238	53572
238	85296
238	51936
238	14008
238	7720
238	44443
238	21609
238	88114
238	67232
238	86766
238	72794
238	28894
238	95563
238	93627
238	12470
238	7553
238	5791
238	82723
238	52133
238	94232
239	22385
239	86817
239	58404
239	53299
239	69960
239	77465
239	68463
239	68471
239	36582
239	83805
239	68611
239	62514
239	70218
239	2668
239	85271
239	52902
239	97602
239	57189
239	30100
239	80877
239	14403
239	2096
240	59164
240	74629
240	67713
240	83968
240	23204
240	51921
240	89975
240	77552
240	4572
240	49502
240	3526
240	70770
240	43380
240	59388
240	60022
240	25067
240	37963
240	91373
240	55047
240	45408
240	46363
240	45405
241	94391
241	63160
241	71342
241	9094
241	85893
241	1298
241	71107
241	74361
241	31892
241	93318
241	83693
241	34572
241	54317
241	50470
241	62861
241	48922
241	26414
241	153
241	18303
241	58374
241	93042
241	39053
242	53935
242	70959
242	15996
242	41343
242	24769
242	89759
242	87338
242	1608
242	40825
242	18032
242	17405
242	60468
242	74741
242	54299
242	26383
242	93081
242	21261
242	48120
243	62296
243	60340
243	84060
243	24862
243	2688
243	70203
243	15966
243	33672
243	14903
243	10128
243	49949
243	78729
243	27968
243	24949
243	47025
243	58392
243	21302
243	85220
244	4945
244	48100
244	54832
244	44333
244	69316
244	19063
244	34495
244	54250
244	81582
244	78731
244	15723
244	75654
244	1739
244	8129
244	18257
244	91091
244	5432
244	54286
245	81922
245	43536
245	1721
245	50609
245	91753
245	3790
245	25916
245	8319
245	65510
245	42117
245	23712
245	80365
245	88749
245	43393
245	74955
245	37679
245	43998
245	75034
246	36095
246	51730
246	63276
246	95856
246	44228
246	48884
246	21423
246	53366
246	30335
246	10757
246	39883
246	76215
246	10018
246	16920
246	25144
246	47441
246	8619
246	58592
247	97777
247	23151
247	10951
247	75268
247	90918
247	2315
247	12901
247	11183
247	89767
247	65393
247	57735
247	71237
247	40727
247	52430
247	49968
247	47660
247	7005
247	50912
248	89545
248	87015
248	27625
248	64525
248	85493
248	50928
248	89192
248	28976
248	41046
248	95229
248	91514
248	46260
248	13746
248	57072
248	77882
248	48890
248	10451
248	29094
249	42839
249	21831
249	54269
249	7169
249	2950
249	55801
249	37507
249	79951
249	16994
249	96912
249	62147
249	23793
249	35084
249	93036
249	75601
249	95282
249	31253
249	85265
250	52654
250	81179
250	26950
250	65225
250	53349
250	89903
250	76883
250	33681
250	32241
250	57488
250	8232
250	59238
250	68759
250	436
250	30411
250	42059
250	24476
250	55437
251	89376
251	29059
251	8403
251	67204
251	36817
251	6023
251	24254
251	91065
251	84389
251	58688
251	35393
251	39183
251	58483
251	3648
251	84789
251	18995
251	54099
251	41995
252	16323
252	8153
252	96118
252	35861
252	57532
252	84182
252	12441
252	24936
252	57215
252	33270
252	81571
252	1275
252	42701
252	31691
252	98080
252	2652
252	3801
252	99713
253	65159
253	90564
253	48379
253	56906
253	29594
253	99201
253	36970
253	10856
253	28901
253	54794
253	89416
253	99328
253	25850
253	30345
253	5397
253	30282
253	13711
253	83809
254	34056
254	53817
254	28816
254	82949
254	78898
254	79080
254	35873
254	14841
254	84542
254	80404
254	16961
254	24755
254	41616
254	6370
254	55916
254	69852
254	65
254	15142
254	7031
254	27629
254	93732
254	87458
255	531
255	72736
255	10129
255	43307
255	61846
255	33618
255	8623
255	51869
255	28230
255	97414
255	88070
255	72937
255	99499
255	39297
255	35636
255	33197
255	83199
255	69659
255	71601
255	54160
255	90526
255	48499
256	83061
256	6645
256	47593
256	49642
256	74977
256	92800
256	44632
256	59235
256	20960
256	22812
256	11058
256	23356
256	70512
256	9423
256	61814
256	26034
256	77469
256	97920
256	66585
256	90575
256	9978
256	84079
257	31850
257	26340
257	61247
257	74676
257	12551
257	90842
257	68671
257	32466
257	12418
257	93386
257	61251
257	2858
257	56505
257	91718
257	7679
257	72471
257	78793
257	86509
257	60969
257	62722
257	81097
257	12835
258	94024
258	88510
258	47670
258	6964
258	7517
258	56496
258	23633
258	81648
258	19567
258	5061
258	40793
258	31099
258	99271
258	67920
258	40749
258	48990
258	24215
258	96679
258	36178
258	22562
258	51016
258	33264
259	17774
259	84420
259	98173
259	33542
259	53341
259	94752
259	77989
259	12458
259	58080
259	59402
259	3377
259	6434
259	7520
259	8703
259	68499
259	63012
259	63522
259	1632
259	43560
259	49445
259	95667
259	93402
260	24621
260	70177
260	33086
260	43980
260	42991
260	31825
260	23692
260	19743
260	27157
260	49600
260	55994
260	2080
260	41894
260	10890
260	92695
260	76247
260	80178
260	28003
260	69504
260	6957
260	10444
260	42369
261	59164
261	47227
261	67713
261	83968
261	87830
261	51921
261	37963
261	77552
261	43380
261	49502
261	71595
261	45405
261	4572
261	59388
261	48681
261	5385
261	68490
261	91373
261	9705
261	61872
261	78222
261	33751
262	7892
262	54632
262	86801
262	43850
262	59135
262	6459
262	68230
262	68233
262	16110
262	12695
262	75239
262	83956
262	35810
262	11986
262	70338
262	98623
262	38731
262	68585
262	87563
262	24277
262	80966
262	20597
263	88002
263	83615
263	24741
263	36036
263	43222
263	42920
263	98192
263	2430
263	80307
263	78756
263	87231
263	93900
263	52474
263	67585
263	96535
263	38434
263	38178
263	26730
263	31072
263	32071
263	78280
263	14001
264	50787
264	78308
264	9363
264	28217
264	21741
264	40627
264	22941
264	21495
264	26316
264	46904
264	97279
264	53503
264	70776
264	97610
264	93217
264	16030
264	82483
264	81177
264	87112
264	35042
264	74788
264	10416
265	74924
265	61342
265	19991
265	82124
265	77110
265	96824
265	45896
265	84885
265	9278
265	37917
265	8730
265	58464
265	61219
265	39021
265	48036
265	89133
265	33746
265	36579
265	91608
265	96488
265	16451
265	62567
266	15829
266	32212
266	92391
266	72919
266	51357
266	50869
266	33834
266	27957
266	92804
266	22409
266	3942
266	4823
266	26572
266	49163
266	29008
266	92458
266	20827
266	61116
266	99166
266	42249
266	25693
266	22351
267	75277
267	39450
267	72134
267	46986
267	74808
267	91949
267	54287
267	91871
267	98228
267	83122
267	22820
267	72487
267	26103
267	84893
267	41790
267	25342
267	25715
267	95888
267	74911
267	34180
267	56969
267	77276
268	3090
268	83152
268	2163
268	90792
268	52878
268	94465
268	48934
268	61579
268	73648
268	72296
268	31031
268	14379
268	48304
268	47297
268	24240
268	63024
268	59890
268	93679
268	21663
268	25644
268	96984
268	50065
269	67839
269	25274
269	99685
269	15882
269	96122
269	91106
269	28854
269	95491
269	42603
269	52963
269	69817
269	7683
269	20706
269	28514
269	90357
269	94106
269	11747
269	4391
269	87036
269	98535
269	15705
269	33377
270	29644
270	12625
270	87995
270	43639
270	86528
270	19537
270	4888
270	83265
270	69340
270	30739
270	54322
270	44978
270	79864
270	81047
270	11979
270	15773
270	67833
270	17898
270	42028
270	44448
270	266
270	47501
271	82210
271	82492
271	6372
271	95639
271	70700
271	66957
271	8785
271	46886
271	73354
271	48249
271	76498
271	1806
271	99207
271	88486
271	42532
271	54805
271	65049
271	83394
271	76220
271	93191
271	69635
271	46493
272	12996
272	60332
272	44462
272	50171
272	51472
272	21550
272	39267
272	23379
272	3048
272	41428
272	89920
272	88041
272	29132
272	78753
272	77098
272	75079
272	2755
272	22789
272	61224
272	60814
272	43829
272	36914
273	20285
273	93017
273	68563
273	53258
273	92215
273	50333
273	97902
273	9742
273	95664
273	39863
273	65525
273	51868
273	35590
273	57959
273	52179
273	55350
273	90303
273	15222
273	64379
273	55097
273	34573
273	95122
274	63214
274	59647
274	20256
274	80697
274	24945
274	35246
274	619
274	60964
274	78385
274	44411
274	23403
274	96053
274	16059
274	18572
274	97666
274	97482
274	74638
274	76590
274	18314
274	3307
274	38878
274	60604
275	94051
275	23360
275	63774
275	39860
275	75066
275	63692
275	42895
275	21234
275	92339
275	63429
275	26281
275	41130
275	34801
275	72332
275	30568
275	59805
275	80132
275	66178
275	60371
275	39634
275	65081
275	7902
276	9954
276	6183
276	14226
276	94830
276	2900
276	26437
276	56818
276	92672
276	1678
276	78318
276	28977
276	91107
276	12283
276	76790
276	43247
276	10499
276	94720
276	71232
276	82747
276	80695
276	16251
276	31551
277	43736
277	76583
277	6020
277	17037
277	8863
277	14008
277	85613
277	96178
277	7720
277	69356
277	67232
277	83591
277	49258
277	77685
277	86464
277	9412
277	12470
277	76191
277	97459
277	82723
277	34393
277	79863
278	59523
278	36187
278	62503
278	61821
278	19145
278	46124
278	77926
278	17776
278	72800
278	11465
278	56286
278	41263
278	1955
278	48797
278	87217
278	98447
278	30671
278	85660
278	78673
278	97196
279	53935
279	27861
279	41343
279	1608
279	97167
279	89759
279	26383
279	17405
279	14897
279	57452
279	18032
279	9559
279	9127
279	74741
279	54299
279	19610
279	57230
279	90420
279	40008
279	10543
280	71792
280	89408
280	26057
280	39552
280	87255
280	28260
280	39878
280	27736
280	76622
280	96858
280	87029
280	52120
280	57996
280	40501
280	36143
280	62330
280	8594
280	51170
280	3186
280	91403
281	62296
281	44067
281	36217
281	17198
281	2688
281	33672
281	47025
281	70203
281	14903
281	10128
281	49949
281	78729
281	27968
281	46333
281	35093
281	51755
281	65910
281	94408
281	95666
281	75180
282	80982
282	56909
282	22662
282	91633
282	80373
282	74955
282	4853
282	8319
282	42117
282	26680
282	93175
282	71560
282	89851
282	49236
282	6433
282	81922
282	73990
282	45540
282	61320
282	47392
283	95119
283	53455
283	78636
283	10209
283	99203
283	85614
283	63458
283	41909
283	19148
283	7772
283	74331
283	3911
283	33331
283	84117
283	70273
283	68761
283	25880
283	98782
283	30070
283	17606
284	99286
284	27293
284	63276
284	2008
284	78183
284	50598
284	21423
284	53366
284	30335
284	10757
284	53623
284	67353
284	61679
284	53205
284	84207
284	52478
284	33252
284	8789
284	49074
284	9165
285	98768
285	78173
285	62310
285	58567
285	26393
285	69979
285	72113
285	95229
285	91514
285	41046
285	57072
285	89192
285	77882
285	70955
285	10900
285	82283
285	29094
285	15690
285	57497
285	46260
286	52654
286	59238
286	26950
286	65225
286	53349
286	85817
286	89903
286	33681
286	32241
286	57488
286	65870
286	93242
286	68759
286	436
286	94567
286	40837
286	38185
286	10791
286	81179
286	30411
287	39183
287	18995
287	67204
287	5714
287	29154
287	84389
287	24254
287	91065
287	84049
287	58688
287	29915
287	89376
287	33146
287	22200
287	79792
287	75121
287	10394
287	98852
287	6023
287	5474
288	16323
288	8153
288	11793
288	12441
288	26509
288	90709
288	33270
288	24936
288	97773
288	81571
288	87263
288	86300
288	82426
288	24285
288	84497
288	57532
288	23090
288	98080
288	90074
288	17354
289	17759
289	39237
289	73318
289	56906
289	75727
289	78370
289	57583
289	10856
289	28901
289	54794
289	89416
289	99328
289	25850
289	30345
289	49668
289	98699
289	47474
289	38343
289	57965
289	65159
290	81085
290	83403
290	28816
290	28597
290	88203
290	82949
290	60203
290	6370
290	84542
290	65
290	62209
290	56385
290	43717
290	65019
290	67181
290	70099
290	60052
290	7031
290	19888
290	94002
290	45030
290	53716
291	80487
291	78149
291	77198
291	46006
291	77565
291	10661
291	29966
291	67358
291	28521
291	46897
291	31537
291	61823
291	99116
291	66639
291	9345
291	18786
291	87315
291	63420
291	16938
291	62915
291	68074
291	37008
292	72937
292	12959
292	33618
292	86884
292	10129
292	8623
292	69659
292	109
292	90633
292	51869
292	28883
292	18623
292	54160
292	97414
292	15154
292	94736
292	39573
292	52358
292	71601
292	1706
292	33197
292	17071
293	31850
293	91718
293	56505
293	9547
293	3658
293	85176
293	10812
293	32466
293	62722
293	74261
293	52008
293	70594
293	63053
293	93839
293	99966
293	39545
293	64142
293	72471
293	79146
293	68671
293	24526
293	2795
294	39700
294	14982
294	47670
294	84375
294	99271
294	56496
294	23633
294	81648
294	99418
294	22562
294	57696
294	94024
294	11736
294	28549
294	1256
294	16713
294	5818
294	40793
294	41316
294	67598
294	26718
294	25506
295	93402
295	97878
295	67168
295	98173
295	7520
295	53197
295	77989
295	6511
295	63012
295	18804
295	61703
295	38724
295	35138
295	33623
295	78387
295	44460
295	7577
295	45873
295	87968
295	84152
295	14458
295	41783
296	26025
296	85132
296	80753
296	79494
296	8453
296	49850
296	91710
296	43934
296	82614
296	85178
296	39251
296	61561
296	15650
296	30572
296	16244
296	84458
296	56057
296	51514
296	76038
296	14852
296	20330
296	74519
297	24621
297	9175
297	848
297	21571
297	71020
297	80178
297	23692
297	19743
297	55994
297	49600
297	10444
297	18252
297	13552
297	77800
297	76247
297	75570
297	522
297	51932
297	69504
297	30514
297	64415
297	2080
298	52310
298	43142
298	31857
298	98512
298	44332
298	85355
298	21803
298	62861
298	58374
298	5779
298	18926
298	96358
298	75377
298	37461
298	42144
298	93377
298	26414
298	59881
298	96110
298	41724
298	76217
298	94668
299	35183
299	57898
299	77711
299	11000
299	79273
299	72404
299	62564
299	2695
299	75330
299	56788
299	28133
299	90473
299	1514
299	87412
299	37132
299	66859
299	4448
299	87668
299	80289
299	86345
299	68055
299	25541
300	13285
300	97840
300	26320
300	15550
300	54003
300	79943
300	81049
300	92367
300	63416
300	94825
300	3532
300	66658
300	93674
300	40570
300	69168
300	63916
300	43959
300	90384
300	89205
300	51130
300	1249
300	61105
301	30371
301	22876
301	56735
301	96540
301	74952
301	80680
301	61954
301	79380
301	26820
301	56430
301	99420
301	51395
301	54985
301	10738
301	56947
301	55991
301	40400
301	19907
301	28482
301	12167
301	74065
301	75179
302	45405
302	53262
302	78998
302	83968
302	87830
302	45408
302	37963
302	49502
302	9705
302	77552
302	62028
302	33751
302	65108
302	83522
302	94904
302	35902
302	67544
302	91373
302	74629
302	84534
302	15678
302	98511
303	56772
303	93633
303	36676
303	52257
303	91754
303	72482
303	62874
303	44661
303	78085
303	38371
303	25470
303	68937
303	54946
303	31741
303	55250
303	92960
303	65077
303	90057
303	11493
303	6693
303	32369
303	315
304	53723
304	29143
304	43222
304	88863
304	36036
304	55511
304	74039
304	39112
304	87231
304	83836
304	52474
304	88002
304	98757
304	42659
304	59777
304	7951
304	69680
304	78756
304	29172
304	35079
304	34670
304	11392
305	65816
305	6565
305	61134
305	40167
305	51917
305	62344
305	49195
305	44917
305	45682
305	97544
305	19136
305	93008
305	98909
305	99080
305	79750
305	16421
305	89092
305	36985
305	99905
305	41974
305	27847
305	15931
306	2366
306	45752
306	61672
306	29629
306	43163
306	3376
306	23890
306	9349
306	84762
306	33594
306	4785
306	58318
306	64961
306	7585
306	17348
306	10510
306	34956
306	55311
306	36022
306	54298
306	24251
306	99803
307	50787
307	78308
307	26108
307	72763
307	83344
307	40627
307	21741
307	21495
307	50252
307	46904
307	88428
307	92932
307	34636
307	35791
307	45941
307	99771
307	80183
307	32594
307	19578
307	77010
307	92547
307	52784
308	62026
308	16954
308	19991
308	66082
308	77110
308	96824
308	45896
308	76158
308	14349
308	56643
308	80057
308	20094
308	36579
308	87059
308	51300
308	84885
308	28649
308	78077
308	32237
308	82124
308	3706
308	89078
309	26572
309	27926
309	46061
309	32212
309	92458
309	27957
309	92804
309	22409
309	59191
309	88946
309	42224
309	34767
309	96131
309	33834
309	76156
309	45916
309	88340
309	15829
309	21832
309	42249
309	30015
309	55197
310	75277
310	1364
310	91148
310	91516
310	74808
310	79669
310	54287
310	56969
310	98228
310	83122
310	76542
310	79585
310	2360
310	84893
310	41790
310	34180
310	39450
310	89782
310	72134
310	25715
310	71220
310	35031
311	14379
311	83152
311	65348
311	25644
311	52878
311	75062
311	48934
311	61579
311	3442
311	72296
311	31031
311	99616
311	31312
311	86211
311	59890
311	94465
311	99732
311	94822
311	25187
311	63924
311	35373
311	21663
312	36426
312	76678
312	14942
312	19241
312	34957
312	11212
312	74664
312	3217
312	98051
312	17884
312	50567
312	75402
312	42797
312	8196
312	40108
312	52469
312	73933
312	34676
312	22146
312	82458
312	78557
312	83261
313	75836
313	12625
313	65453
313	6854
313	17898
313	19537
313	1137
313	4888
313	67833
313	30739
313	70680
313	44978
313	16780
313	27750
313	66588
313	53546
313	54322
313	48638
313	44448
313	79864
313	43055
313	29644
314	12996
314	55518
314	44462
314	50171
314	51472
314	21550
314	92151
314	85019
314	88041
314	41428
314	89920
314	81321
314	73110
314	78753
314	30161
314	17941
314	53448
314	20886
314	28313
314	61224
314	43829
314	45367
315	85003
315	95707
315	48864
315	77029
315	68779
315	39255
315	189
315	74264
315	39265
315	56227
315	39646
315	28281
315	25813
315	30400
315	85724
315	96166
315	2421
315	14701
315	54290
315	51888
315	1355
315	60841
316	57626
316	28712
316	10490
316	94478
316	92802
316	5915
316	2423
316	19030
316	24299
316	85624
316	88704
316	45250
316	37844
316	32294
316	47572
316	16070
316	59298
316	85237
316	56543
316	54426
316	65806
316	97369
316	83595
317	84722
317	17666
317	65241
317	51868
317	66219
317	75255
317	54653
317	9742
317	2853
317	72495
317	65525
317	54130
317	96267
317	64624
317	47850
317	64908
317	55350
317	15222
317	75418
317	55097
317	85453
317	56801
318	63214
318	59647
318	60583
318	76590
318	24945
318	35246
318	8514
318	60964
318	75598
318	24556
318	34
318	96053
318	16059
318	22620
318	8700
318	8262
318	93745
318	61706
318	64962
318	3307
318	38878
318	57289
319	23480
319	90120
319	73316
319	25497
319	82870
319	48736
319	47506
319	22242
319	89922
319	41620
319	15025
319	668
319	89154
319	28789
319	58711
319	12180
319	44011
319	88921
319	49604
319	16851
319	10094
319	52641
320	76191
320	34695
320	2842
320	6020
320	8863
320	68379
320	69356
320	96178
320	86464
320	7720
320	67232
320	72797
320	49258
320	25779
320	18539
320	83591
320	12470
320	7553
320	36074
320	60597
320	97459
320	79863
321	69448
321	12268
321	80898
321	27338
321	72969
321	15547
321	69912
321	18303
321	82329
321	93318
321	4188
321	39053
321	43392
321	35544
321	57880
321	11960
321	48250
321	40701
321	45323
321	22793
321	85140
321	33080
322	70336
322	99108
322	23968
322	36187
322	1955
322	46124
322	98447
322	19145
322	61821
322	72800
322	44064
322	86048
322	56574
322	4506
322	20570
322	75511
322	72006
322	77926
322	35111
322	59523
323	64203
323	9127
323	41343
323	10543
323	96106
323	11872
323	67574
323	19610
323	90420
323	57452
323	89410
323	66036
323	89759
323	78266
323	89908
323	15996
323	26383
323	58199
323	27861
323	62970
324	9794
324	76722
324	50457
324	29054
324	87255
324	28260
324	39878
324	56271
324	76622
324	26057
324	57254
324	97696
324	70567
324	73728
324	36143
324	18666
324	8594
324	85899
324	86965
324	41105
325	63535
325	44067
325	36217
325	94408
325	46333
325	65910
325	70314
325	9811
325	14903
325	10128
325	67766
325	78729
325	48897
325	16075
325	84161
325	68281
325	20612
325	75180
325	79018
325	51393
326	80982
326	73900
326	73990
326	91633
326	74964
326	61320
326	56909
326	75034
326	47392
326	93175
326	57369
326	60476
326	37513
326	80373
326	2005
326	54677
326	20383
326	64823
326	34416
326	81866
327	36668
327	27862
327	78246
327	70251
327	44228
327	61679
327	21423
327	49074
327	52478
327	53366
327	50598
327	67283
327	53205
327	33252
327	54576
327	42444
327	8789
327	27479
327	90924
327	73519
328	42042
328	90753
328	44808
328	21048
328	86407
328	36715
328	14240
328	78239
328	99818
328	84231
328	47674
328	89564
328	12997
328	52361
328	84404
328	75315
328	54127
328	45660
328	90520
328	14601
329	71237
329	52348
329	58574
329	62383
329	67779
329	58581
329	50912
329	573
329	6810
329	49769
329	41283
329	13129
329	30583
329	11183
329	47822
329	81336
329	11042
329	12901
329	87749
329	79263
330	57497
330	62310
330	36151
330	91945
330	46224
330	69979
330	78173
330	74200
330	29094
330	72113
330	82283
330	51492
330	24967
330	32368
330	4884
330	69292
330	48735
330	17805
330	33014
330	39010
331	50573
331	99657
331	48441
331	2698
331	52285
331	23661
331	69880
331	2679
331	77515
331	92275
331	42124
331	11308
331	1717
331	40960
331	44473
331	37772
331	15055
331	9352
331	60080
331	7466
332	52654
332	85817
332	27461
332	38386
332	22479
332	34716
332	19498
332	33681
332	81834
332	57488
332	65870
332	26109
332	68759
332	59238
332	94567
332	75280
332	5883
332	10791
332	93242
332	38422
333	84527
333	78097
333	7307
333	16179
333	7247
333	89690
333	16375
333	44185
333	48268
333	16569
333	16650
333	31902
333	67441
333	14030
333	46500
333	59010
333	84344
333	18796
333	23894
333	38181
334	39183
334	4956
334	1272
334	31385
334	83715
334	84389
334	98852
334	78069
334	29915
334	58688
334	75121
334	49113
334	74483
334	5714
334	49154
334	70069
334	556
334	6090
334	65709
334	72974
335	46594
335	81945
335	75205
335	31383
335	65831
335	37971
335	55158
335	62577
335	23016
335	90659
335	42830
335	26579
335	90185
335	20242
335	42638
335	69415
335	14186
335	18197
335	95777
335	51247
336	91428
336	33354
336	84530
336	24285
336	26509
336	52220
336	47163
336	36318
336	97773
336	31388
336	36470
336	3139
336	62434
336	60653
336	53787
336	98034
336	23207
336	31442
336	20773
336	30916
337	17759
337	53620
337	471
337	56906
337	75727
337	99201
337	71411
337	14832
337	28901
337	54794
337	89416
337	18634
337	25850
337	30345
337	49668
337	98699
337	24048
337	38343
337	34806
337	58480
338	56385
338	83403
338	60914
338	31684
338	88203
338	76131
338	60203
338	53716
338	84542
338	65
338	62209
338	60052
338	2174
338	6370
338	26200
338	25906
338	45985
338	11130
338	19888
338	94002
338	35873
338	28816
338	12056
339	48592
339	17071
339	94736
339	71601
339	28883
339	80262
339	69659
339	34376
339	64922
339	3447
339	52358
339	2977
339	12777
339	91831
339	12842
339	21070
339	42565
339	46499
339	88716
339	3038
339	33197
339	90633
339	44716
340	64377
340	91718
340	42918
340	66308
340	9270
340	85176
340	57975
340	45956
340	62722
340	74261
340	57361
340	2795
340	93236
340	9454
340	79283
340	29601
340	79146
340	6280
340	20389
340	26695
340	89804
340	1939
340	58388
341	41783
341	60766
341	67168
341	98173
341	7520
341	53197
341	78387
341	86465
341	61703
341	18804
341	67466
341	38724
341	83436
341	60079
341	63567
341	93402
341	63522
341	99681
341	56970
341	84152
341	14458
341	59683
341	18536
342	31496
342	77096
342	83943
342	29611
342	24535
342	37402
342	50519
342	28870
342	5235
342	27445
342	19411
342	5845
342	13701
342	12619
342	90061
342	57338
342	60686
342	71211
342	68056
342	84550
342	39905
342	2177
342	92129
343	74709
343	56632
343	50749
343	56613
343	32696
343	67575
343	3776
343	26474
343	22046
343	68890
343	55170
343	20880
343	75965
343	56119
343	85975
343	14189
343	2273
343	86109
343	98663
343	96930
343	29122
343	73169
343	74506
344	85818
344	31857
344	29621
344	87187
344	55293
344	70100
344	10638
344	62861
344	58374
344	84378
344	50470
344	99830
344	75377
344	37461
344	36689
344	91190
344	26414
344	13265
344	96110
344	41724
344	61666
344	53874
344	94668
345	212
345	37132
345	86345
345	27808
345	79273
345	72404
345	24031
345	63778
345	50534
345	68055
345	80289
345	34389
345	94452
345	26759
345	89928
345	25541
345	46718
345	41271
345	80170
345	5337
345	6985
345	21988
345	4393
346	11930
346	59372
346	98031
346	92146
346	37753
346	32567
346	74323
346	28455
346	3128
346	23101
346	19156
346	47469
346	85736
346	85473
346	90857
346	99914
346	6468
346	86943
346	42534
346	30306
346	87016
346	53809
346	39602
347	13285
347	68164
347	16557
347	53590
347	1249
347	97840
347	81049
347	63916
347	10663
347	51130
347	8307
347	55244
347	93674
347	91486
347	90384
347	79943
347	94825
347	61216
347	37933
347	447
347	3723
347	59324
347	34406
348	59735
348	22876
348	56735
348	96540
348	62062
348	80680
348	93048
348	79380
348	53533
348	56430
348	916
348	51395
348	66615
348	10738
348	56947
348	55991
348	40400
348	19907
348	23315
348	12167
348	74065
348	57906
348	57021
349	33751
349	17520
349	71726
349	73157
349	57588
349	67544
349	55504
349	35902
349	45490
349	97252
349	27787
349	98511
349	84003
349	25543
349	51287
349	65108
349	3026
349	42820
349	32136
349	84534
349	4065
349	35264
349	5630
350	11392
350	45258
350	43222
350	15450
350	88863
350	57378
350	83836
350	18164
350	29172
350	42038
350	68818
350	81393
350	55511
350	42659
350	84093
350	59777
350	26847
350	17035
350	42227
350	1311
350	34670
350	53723
350	37126
351	54298
351	34956
351	21222
351	49610
351	46807
351	64961
351	9349
351	17348
351	99721
351	84762
351	96566
351	24251
351	35882
351	42311
351	89292
351	95259
351	11915
351	4785
351	12376
351	58878
351	79993
351	48525
351	94511
352	52784
352	50893
352	87592
352	44763
352	13917
352	89297
352	98036
352	21495
352	81643
352	88428
352	19578
352	92932
352	87229
352	72763
352	45941
352	32594
352	80183
352	57272
352	76755
352	36826
352	92547
352	56348
352	50787
353	22507
353	64104
353	91148
353	91516
353	19121
353	79669
353	27347
353	56969
353	48550
353	83122
353	76542
353	47983
353	55727
353	3741
353	3331
353	6935
353	74228
353	48288
353	22123
353	52108
353	64893
353	39249
353	52099
354	36426
354	76678
354	50567
354	19241
354	34957
354	66123
354	55673
354	87796
354	34530
354	17884
354	78557
354	94060
354	42797
354	75108
354	22302
354	3401
354	22263
354	50109
354	96044
354	98051
354	82458
354	93337
354	88899
355	59886
355	99558
355	66681
355	15578
355	20085
355	53829
355	34709
355	93812
355	69995
355	29986
355	75230
355	13151
355	37701
355	3927
355	68907
355	68833
355	90321
355	49007
355	7088
355	46873
355	6017
355	1018
355	9579
356	16675
356	73722
356	39199
356	48643
356	23927
356	70308
356	57496
356	70698
356	57982
356	62808
356	88800
356	83823
356	82191
356	6162
356	67041
356	45712
356	91925
356	11424
356	7559
356	92307
356	57631
356	37140
356	61068
357	32512
357	56778
357	59412
357	57630
357	69817
357	91106
357	15705
357	105
357	18106
357	84878
357	32499
357	34285
357	20792
357	22209
357	98853
357	79072
357	51629
357	7683
357	83418
357	74235
357	19727
357	57284
357	33377
358	86448
358	70372
358	70700
358	79578
358	27678
358	65105
358	83394
358	48249
358	66907
358	76220
358	76498
358	82210
358	32046
358	64408
358	51792
358	89971
358	75536
358	53680
358	76375
358	14715
358	28437
358	4731
358	76203
359	12996
359	55518
359	90725
359	50171
359	16522
359	48349
359	92151
359	90435
359	88041
359	11262
359	85019
359	53448
359	77199
359	76946
359	26868
359	17941
359	75813
359	20886
359	585
359	683
359	99270
359	29107
359	12568
360	16571
360	27229
360	81968
360	50303
360	82601
360	95302
360	1462
360	75923
360	5029
360	62977
360	84943
360	42976
360	16046
360	62939
360	35019
360	2673
360	37924
360	91308
360	82212
360	35460
360	35489
360	58665
360	64668
361	49309
361	22318
361	84477
361	13966
361	48946
361	4672
361	75494
361	22187
361	48910
361	64619
361	6135
361	55616
361	30524
361	75095
361	26609
361	12511
361	68168
361	44943
361	31903
361	74981
361	649
361	32449
361	54102
362	57626
362	72876
362	14062
362	65611
362	10439
362	21000
362	2423
362	30964
362	65059
362	53464
362	27802
362	99521
362	65806
362	22393
362	5390
362	57595
362	59298
362	37844
362	56543
362	13782
362	38095
362	68024
362	73319
363	95122
363	26659
363	17666
363	7865
363	51785
363	75255
363	96267
363	37114
363	56626
363	46519
363	72495
363	84722
363	60562
363	22338
363	66219
363	39884
363	68095
363	15222
363	26616
363	55097
363	25724
363	83544
363	42690
364	61793
364	19229
364	29082
364	20643
364	51089
364	35246
364	24556
364	23800
364	8514
364	71130
364	24963
364	23336
364	45039
364	21683
364	40852
364	37161
364	76612
364	14456
364	29415
364	3307
364	38878
364	70144
364	95116
365	7902
365	6256
365	63774
365	56718
365	53821
365	5583
365	42808
365	85432
365	84022
365	45212
365	42895
365	22071
365	95369
365	35312
365	68329
365	30568
365	59548
365	20557
365	74139
365	62207
365	80105
365	71531
365	47401
366	52641
366	10094
366	22242
366	44407
366	640
366	82870
366	72780
366	15858
366	89922
366	41620
366	15025
366	87702
366	89154
366	55391
366	76769
366	58954
366	47506
366	99847
366	32986
366	63935
366	668
366	56293
366	44011
367	61478
367	52032
367	94559
367	79130
367	44850
367	37782
367	31907
367	63089
367	58212
367	21108
367	23883
367	49485
367	59617
367	16859
367	98680
367	4455
367	41133
367	65298
367	58069
367	78533
367	46497
367	31566
367	5081
368	76191
368	34695
368	9888
368	58649
368	88043
368	68379
368	97784
368	96178
368	86464
368	97459
368	38074
368	72797
368	49258
368	77238
368	78068
368	49219
368	91976
368	7553
368	43736
368	60597
368	5728
368	92064
368	2842
369	91888
369	17321
369	31352
369	38683
369	76244
369	49428
369	45056
369	41694
369	74863
369	30094
369	95938
369	79836
369	64372
369	3960
369	22489
369	3231
369	46554
369	48761
369	87205
369	66684
369	86087
369	97963
369	54429
370	71063
370	71461
370	66491
370	92592
370	14157
370	386
370	20634
370	84467
370	17212
370	23308
370	34390
370	19263
370	27330
370	91838
370	70312
370	44227
370	95150
370	17521
370	60387
370	80199
371	77947
371	29106
371	30671
371	35111
371	19145
371	55691
371	72006
371	1374
371	69209
371	4506
371	47947
371	64332
371	16853
371	36789
371	66483
371	5773
371	12322
371	30996
371	75511
371	64907
372	66036
372	64954
372	11872
372	10543
372	31275
372	78286
372	19610
372	54956
372	78447
372	7458
372	93057
372	73954
372	22757
372	85281
372	42794
372	67574
372	90420
372	46780
372	58199
372	84576
373	41105
373	74702
373	86178
373	15381
373	87255
373	50457
373	39878
373	85437
373	35069
373	26057
373	20
373	97813
373	28528
373	80374
373	20854
373	36636
373	8594
373	77759
373	33982
373	76027
374	63535
374	66785
374	83032
374	79018
374	36217
374	65910
374	16075
374	70314
374	14903
374	48897
374	67766
374	66877
374	14537
374	44137
374	88622
374	95180
374	71089
374	28220
374	73561
374	44067
375	18967
375	90240
375	24658
375	75036
375	93602
375	45480
375	20811
375	25958
375	17746
375	63727
375	18018
375	22371
375	67223
375	50881
375	62829
375	44882
375	90667
375	34391
375	34640
375	60897
376	36668
376	27862
376	15303
376	41816
376	70251
376	42444
376	8789
376	49074
376	52478
376	53366
376	80012
376	50305
376	53205
376	50598
376	54576
376	85840
376	78246
376	8780
376	6382
376	9674
377	42042
377	96825
377	3333
377	90753
377	40027
377	52992
377	14601
377	68909
377	3320
377	47674
377	23665
377	11692
377	84693
377	86407
377	99818
377	12997
377	8624
377	14240
377	47004
377	75315
378	17805
378	89192
378	51492
378	24220
378	46224
378	69292
378	5860
378	32368
378	24437
378	72113
378	36911
378	57497
378	91945
378	78180
378	94257
378	37697
378	24967
378	30837
378	80867
378	4310
379	40837
379	16023
379	65689
379	55990
379	21975
379	34716
379	19498
379	23079
379	86360
379	93242
379	5883
379	93339
379	68759
379	38422
379	94567
379	75280
379	59238
379	10791
379	68804
379	37759
380	84527
380	78097
380	97743
380	2141
380	77201
380	59010
380	15227
380	65322
380	46500
380	83602
380	23894
380	63421
380	98467
380	61977
380	69790
380	49268
380	80442
380	16375
380	25564
381	39183
381	4956
381	25199
381	78069
381	72897
381	84389
381	29694
381	70069
381	556
381	72974
381	75121
381	66369
381	6090
381	49154
381	5014
381	36571
381	65709
381	45895
381	80834
381	60731
382	46594
382	95777
382	75205
382	24480
382	64409
382	37971
382	55158
382	23016
382	94171
382	90659
382	42830
382	26579
382	90185
382	43351
382	18197
382	71664
382	17206
382	45845
382	69440
382	51516
383	60130
383	86212
383	98861
383	23583
383	93888
383	76130
383	40778
383	94525
383	63581
383	32577
383	67755
383	16593
383	7222
383	82107
383	25247
383	30579
383	16803
383	76840
383	37119
383	65913
384	82146
384	33354
384	84530
384	62434
384	26509
384	52220
384	32488
384	86496
384	97773
384	31388
384	36470
384	85779
384	91907
384	23207
384	95194
384	98034
384	56708
384	82102
384	28523
384	29677
385	17759
385	80622
385	471
385	27814
385	75727
385	99201
385	92403
385	14832
385	28901
385	96012
385	89416
385	18634
385	25850
385	30345
385	58480
385	98699
385	17219
385	42208
385	1853
385	89236
386	24930
386	66972
386	61845
386	6457
386	44205
386	45235
386	14307
386	88171
386	86226
386	7482
386	22865
386	4803
386	13744
386	74131
386	40794
386	78483
386	95366
386	30892
386	31166
386	3457
386	75104
386	24893
386	91786
387	86290
387	83403
387	60914
387	78133
387	66229
387	64352
387	38901
387	77063
387	19888
387	85199
387	29080
387	27047
387	73619
387	27419
387	91357
387	25906
387	16541
387	33570
387	14758
387	38198
387	56532
387	48161
387	66580
388	78863
388	91832
388	66908
388	44926
388	21864
388	24935
388	83566
388	26858
388	78071
388	14290
388	6205
388	6384
388	63129
388	60008
388	59039
388	69089
388	92892
388	55125
388	6754
388	14862
388	90087
388	36196
388	84486
389	2795
389	91718
389	42918
389	98607
389	52008
389	85176
389	20372
389	58388
389	62722
389	57361
389	39545
389	1939
389	47627
389	32968
389	74340
389	30363
389	45956
389	87223
389	37735
389	57975
389	54042
389	11275
389	13354
390	86109
390	56632
390	50749
390	52458
390	32696
390	30163
390	57722
390	26474
390	22046
390	68890
390	55170
390	12856
390	1674
390	7614
390	85975
390	13659
390	97927
390	66817
390	55781
390	37092
390	17028
390	71248
390	82853
391	85818
391	97008
391	29621
391	61666
391	42144
391	91190
391	41724
391	13539
391	12373
391	84378
391	36053
391	59970
391	87187
391	29491
391	31316
391	92627
391	38099
391	13265
391	76289
391	31857
391	53874
391	15428
391	99830
392	53062
392	86056
392	26250
392	69743
392	23972
392	35103
392	40666
392	56023
392	81477
392	29090
392	64760
392	36056
392	46512
392	4349
392	14907
392	44775
392	65749
392	21701
392	30878
392	65590
392	91280
392	54533
392	7338
393	29399
393	72804
393	98031
393	92146
393	36290
393	54675
393	17733
393	42534
393	51733
393	3128
393	19156
393	18894
393	75905
393	96174
393	90857
393	49265
393	6468
393	61229
393	5227
393	30306
393	86943
393	27162
393	63618
394	72859
394	66658
394	16557
394	62157
394	1249
394	71420
394	81049
394	65534
394	99967
394	51130
394	37933
394	97840
394	59324
394	91486
394	50944
394	61216
394	17428
394	50718
394	64864
394	86227
394	77532
394	57447
394	24015
395	30652
395	63176
395	4469
395	96540
395	68803
395	93048
395	18830
395	51388
395	31668
395	56430
395	916
395	51395
395	66615
395	48944
395	56947
395	55991
395	98022
395	58415
395	23315
395	12167
395	43681
395	55659
395	57021
396	98511
396	50326
396	43481
396	27557
396	51287
396	94304
396	43400
396	35264
396	27261
396	55504
396	27787
396	33751
396	84003
396	25543
396	73973
396	18599
396	2328
396	8154
396	32136
396	36287
396	4065
396	24324
396	30693
397	17027
397	24586
397	38556
397	84395
397	29967
397	3949
397	52437
397	12805
397	49882
397	9728
397	50641
397	98986
397	384
397	79316
397	25083
397	97589
397	23035
397	77757
397	70474
397	23846
397	27915
397	81778
397	51458
398	18605
398	93633
398	2909
398	20762
398	96490
398	59901
398	34386
398	16416
398	47539
398	38371
398	56998
398	74059
398	55405
398	20969
398	13809
398	64146
398	60564
398	43423
398	94570
398	56844
398	16154
398	55739
398	111
399	11392
399	14267
399	99473
399	65802
399	88863
399	26539
399	83836
399	18164
399	96512
399	42038
399	48645
399	88263
399	55511
399	69103
399	38599
399	22378
399	97154
399	29172
399	42227
399	57529
399	99537
399	70140
399	37126
400	31283
400	48722
400	8544
400	25398
400	48968
400	80902
400	14259
400	67250
400	14175
400	58634
400	99466
400	12127
400	97294
400	64184
400	93241
400	51266
400	20335
400	98071
400	44934
400	75763
400	92316
400	55581
400	30753
401	24251
401	65411
401	46091
401	61292
401	11915
401	95259
401	9349
401	12376
401	56897
401	77277
401	17506
401	40995
401	35882
401	42311
401	89292
401	10636
401	46807
401	4785
401	99888
401	15134
401	87604
401	90430
401	54298
402	92932
402	78308
402	97434
402	44763
402	98486
402	89297
402	30651
402	34636
402	81643
402	73255
402	98036
402	5120
402	80826
402	10860
402	86098
402	77467
402	89438
402	40312
402	34977
402	87592
402	92547
402	11191
402	17445
403	26572
403	81414
403	46895
403	40197
403	21832
403	18113
403	33312
403	42224
403	3013
403	68125
403	23705
403	65694
403	96131
403	28832
403	13377
403	66598
403	99934
403	69700
403	63856
403	51336
403	17967
403	3558
403	36850
404	94060
404	429
404	42228
404	19241
404	50109
404	22302
404	54903
404	44396
404	34530
404	17884
404	75108
404	53378
404	42797
404	30891
404	22470
404	78654
404	51433
404	71995
404	35595
404	99403
404	82458
404	26126
404	88899
405	32695
405	63796
405	10771
405	12680
405	24493
405	46873
405	5425
405	49007
405	7088
405	86811
405	21451
405	34895
405	75168
405	15578
405	95900
405	52481
405	2210
405	97704
405	37586
405	41668
405	13524
405	57476
405	67164
406	45712
406	16378
406	48643
406	55321
406	53943
406	80908
406	57496
406	92307
406	57982
406	83823
406	32279
406	86534
406	28497
406	62437
406	68375
406	37760
406	70442
406	17581
406	21434
406	96343
406	57631
406	55784
406	83900
407	12996
407	53448
407	90725
407	48279
407	84226
407	585
407	21753
407	90435
407	88041
407	11262
407	88984
407	76946
407	77199
407	50973
407	58952
407	66016
407	60833
407	20886
407	33367
407	87114
407	99270
407	95677
407	69611
408	34336
408	41907
408	50226
408	8415
408	68901
408	41962
408	50012
408	37893
408	48250
408	22793
408	33481
408	48430
408	58429
408	64659
408	79645
408	8113
408	85128
408	25611
408	18094
408	55456
408	87039
408	5783
408	46403
409	95122
409	94594
409	61550
409	7865
409	51785
409	76780
409	25724
409	65040
409	26616
409	6608
409	56626
409	46519
409	60562
409	22338
409	89943
409	4977
409	92775
409	56299
409	20248
409	50318
409	8539
409	83544
409	55485
410	61793
410	63942
410	28485
410	15314
410	51089
410	21683
410	24556
410	29415
410	71661
410	83711
410	25905
410	13964
410	56330
410	73924
410	89177
410	82549
410	70144
410	81297
410	16059
410	51440
410	49097
410	73344
410	44334
411	47401
411	75070
411	6256
411	30568
411	35312
411	5583
411	42808
411	85432
411	84022
411	80105
411	42895
411	2115
411	20273
411	19165
411	44340
411	73608
411	79017
411	20557
411	62207
411	45212
411	65907
411	7148
411	95996
412	38789
412	25758
412	82814
412	94161
412	63929
412	17148
412	11817
412	56006
412	61684
412	35674
412	87221
412	46325
412	49127
412	6129
412	35818
412	97143
412	10953
412	46417
412	54713
412	37656
412	7302
412	59636
412	10789
413	8028
413	41085
413	3523
413	48772
413	8365
413	43931
413	57309
413	8310
413	12652
413	64772
413	21511
413	1401
413	58731
413	44097
413	80410
413	30416
413	4210
413	22298
413	77
413	53024
413	10224
413	60422
413	98500
414	9117
414	57974
414	86728
414	77807
414	52480
414	49762
414	5918
414	40120
414	77687
414	61974
414	52850
414	56282
414	78050
414	88830
414	33665
414	3524
414	23065
414	22492
414	94201
414	62644
414	74150
414	34430
414	26454
415	52641
415	31347
415	72448
415	96363
415	640
415	82870
415	33293
415	69034
415	27618
415	41620
415	9041
415	61850
415	89154
415	63068
415	76769
415	66577
415	54768
415	69430
415	40581
415	61670
415	8678
415	79202
415	91602
416	91649
416	17420
416	96896
416	60675
416	35676
416	7368
416	86650
416	56584
416	82307
416	99083
416	56553
416	37090
416	32374
416	47335
416	69073
416	58919
416	27508
416	60032
416	98387
416	55388
416	67256
416	18200
416	96162
417	50522
417	59999
417	12548
417	58649
417	88043
417	77238
417	97784
417	18672
417	80859
417	97459
417	71080
417	9888
417	83190
417	60945
417	42535
417	78068
417	91976
417	7553
417	92673
417	60597
417	5728
417	87765
417	2842
418	71063
418	24548
418	95150
418	65068
418	2875
418	60387
418	66590
418	71461
418	84467
418	24460
418	23308
418	19263
418	8904
418	24795
418	80712
418	4287
418	91838
418	5215
418	82027
418	92491
418	69918
419	64332
419	14085
419	56574
419	35111
419	19145
419	55691
419	47947
419	42226
419	26286
419	4506
419	83079
419	91505
419	15139
419	87492
419	74624
419	82607
419	12322
419	94956
419	35812
419	21039
419	33547
420	66036
420	81163
420	84724
420	10543
420	31275
420	85281
420	46780
420	19610
420	67574
420	7458
420	93057
420	61069
420	22757
420	78266
420	90420
420	64954
420	25746
420	26383
420	78286
420	58459
420	50674
421	41105
421	85437
421	2636
421	3906
421	87255
421	77759
421	35069
421	28528
421	19025
421	62671
421	20
421	97813
421	70567
421	27120
421	20854
421	33304
421	36636
421	33982
421	95092
421	76027
421	44161
422	43215
422	53317
422	83032
422	54442
422	48604
422	57621
422	44137
422	71089
422	73561
422	52970
422	67766
422	66877
422	51360
422	70314
422	26568
422	95180
422	85561
422	63535
422	23604
422	72394
422	74705
423	58449
423	82713
423	80373
423	51843
423	17894
423	56909
423	11819
423	24775
423	5784
423	71560
423	57369
423	30396
423	20868
423	6237
423	60168
423	36403
423	23254
423	74383
423	99432
423	74183
423	22569
424	40412
424	22178
424	77877
424	73084
424	81136
424	98782
424	34666
424	10986
424	38733
424	12357
424	38142
424	45870
424	55474
424	16452
424	85483
424	41187
424	81958
424	98538
424	88697
424	79856
424	78748
425	54576
425	27862
425	96080
425	59869
425	67377
425	15303
425	39260
425	49074
425	52478
425	42444
425	30564
425	95839
425	53205
425	47092
425	50305
425	80012
425	78246
425	8780
425	54473
425	50575
425	36668
426	75315
426	96825
426	3333
426	56710
426	40027
426	52992
426	93979
426	54127
426	68145
426	47674
426	23665
426	68729
426	84693
426	1062
426	12997
426	42042
426	5170
426	68309
426	11692
426	8624
426	77841
427	38266
427	51492
427	49475
427	78180
427	24967
427	74200
427	32368
427	46224
427	24437
427	72113
427	36911
427	17805
427	33014
427	96331
427	55574
427	4310
427	20246
427	86882
427	99210
427	84771
427	43213
428	59575
428	61084
428	83259
428	82898
428	393
428	46683
428	13547
428	11940
428	16994
428	80895
428	21210
428	40693
428	69129
428	73751
428	32154
428	80600
428	22277
428	58561
428	52525
428	38007
428	40496
429	93339
429	16023
429	1039
429	55990
429	21975
429	72499
429	19498
429	38422
429	1517
429	19149
429	29682
429	65033
429	26654
429	86360
429	94567
429	69273
429	85817
429	16613
429	94784
429	95386
429	56097
430	30107
430	93587
430	8347
430	89322
430	63421
430	83860
430	65322
430	96884
430	7625
430	59010
430	96153
430	61977
430	476
430	68017
430	79610
430	83515
430	21807
430	92164
430	33928
430	67990
431	39183
431	25199
431	36571
431	68132
431	51925
431	38523
431	29694
431	70069
431	9212
431	30339
431	97621
431	1929
431	42549
431	42222
431	15475
431	74483
431	95127
431	8869
431	5014
431	60731
431	25739
432	27779
432	33354
432	48787
432	62434
432	94354
432	66882
432	32488
432	96721
432	31442
432	31388
432	36470
432	85779
432	82102
432	91907
432	95194
432	85545
432	28917
432	52228
432	40792
432	5293
432	51033
433	17759
433	95448
433	471
433	27814
433	40936
433	49030
433	92403
433	25717
433	54396
433	96012
433	62104
433	17276
433	25850
433	24266
433	58480
433	1853
433	69030
433	80833
433	75460
433	89236
433	49425
434	98886
434	21116
434	957
434	77742
434	19453
434	30221
434	70903
434	23484
434	22008
434	44112
434	10693
434	92503
434	63647
434	9837
434	42107
434	17205
434	37702
434	21704
434	70560
434	9059
434	46257
434	94880
434	596
435	70815
435	39810
435	93262
435	56532
435	6108
435	64352
435	42113
435	62209
435	29398
435	14758
435	29080
435	5459
435	76131
435	77063
435	49114
435	36870
435	56859
435	60592
435	28014
435	33570
435	55451
435	60541
435	91484
436	78863
436	91832
436	66908
436	44926
436	21864
436	69089
436	83566
436	14862
436	6754
436	14290
436	60008
436	33989
436	63129
436	96211
436	37275
436	70545
436	31145
436	7864
436	64711
436	36196
436	3552
436	73512
436	84486
437	11275
437	94551
437	42918
437	98607
437	58840
437	86163
437	78264
437	45956
437	98528
437	58388
437	13354
437	27402
437	9441
437	32968
437	32798
437	30363
437	74066
437	86499
437	29075
437	79283
437	25449
437	61927
437	82456
438	59683
438	44116
438	93209
438	98173
438	68512
438	99407
438	88732
438	86465
438	61703
438	96890
438	67012
438	47081
438	6117
438	86625
438	10830
438	44262
438	53593
438	48455
438	48783
438	48097
438	47974
438	94440
438	53452
439	89601
439	98593
439	23300
439	16376
439	29404
439	41671
439	30014
439	41001
439	66477
439	65631
439	35574
439	52362
439	8305
439	96009
439	74480
439	31755
439	49014
439	21890
439	67949
439	39840
439	90807
439	8708
439	11751
440	212
440	46718
440	14988
440	52264
440	93951
440	13831
440	18657
440	63778
440	50534
440	68055
440	38862
440	47232
440	83625
440	67264
440	89870
440	83165
440	45005
440	5707
440	80170
440	41303
440	50104
440	21988
440	23395
441	59324
441	43764
441	16557
441	62157
441	6000
441	71420
441	64864
441	65534
441	77532
441	99967
441	37933
441	84201
441	44282
441	69235
441	41152
441	95616
441	48335
441	50944
441	42890
441	16073
441	8307
441	50718
441	64443
442	30711
442	69530
442	4469
442	94643
442	68803
442	13394
442	55659
442	72795
442	53533
442	31668
442	42706
442	51395
442	72916
442	9884
442	18830
442	69594
442	33400
442	58415
442	82555
442	84312
442	57240
442	77249
442	38004
443	19408
443	50326
443	43481
443	4201
443	3879
443	13029
443	43400
443	12818
443	88148
443	36287
443	27787
443	68199
443	28154
443	47255
443	47324
443	18599
443	2328
443	39356
443	10713
443	4224
443	97093
443	5630
443	78594
444	79898
444	24586
444	38556
444	25083
444	29967
444	50270
444	43176
444	93750
444	49882
444	9728
444	50641
444	69641
444	1945
444	79316
444	56448
444	29011
444	79884
444	65216
444	56284
444	6223
444	39956
444	81778
444	66316
445	51633
445	70793
445	70421
445	69064
445	47188
445	10140
445	58348
445	36090
445	32124
445	17698
445	28140
445	83927
445	7928
445	75292
445	5210
445	50181
445	56893
445	45647
445	11436
445	59270
445	52378
445	8522
445	84614
446	14138
446	53363
446	31125
446	23032
446	82662
446	45221
446	50967
446	15185
446	59301
446	73160
446	54804
446	91430
446	53060
446	93922
446	88160
446	71236
446	97689
446	93059
446	6476
446	4726
446	57482
446	81025
446	7624
447	11392
447	11109
447	54694
447	92874
447	88863
447	65802
447	47246
447	18164
447	38599
447	75306
447	48645
447	30116
447	36764
447	19910
447	37848
447	22378
447	6005
447	1045
447	42227
447	27627
447	99537
447	37678
447	57248
448	30753
448	19422
448	8544
448	25398
448	48968
448	4746
448	63253
448	31976
448	19801
448	33586
448	99466
448	50281
448	55581
448	77484
448	93241
448	77464
448	59702
448	98071
448	44934
448	75763
448	92316
448	55416
448	64945
449	24251
449	148
449	46091
449	29462
449	26303
449	35179
449	61292
449	3497
449	84807
449	77277
449	15134
449	89840
449	28659
449	16260
449	85824
449	90491
449	91793
449	33175
449	12781
449	46807
449	53272
449	90430
449	54298
450	52784
450	11191
450	97434
450	44763
450	98486
450	89297
450	80043
450	2461
450	73255
450	88428
450	68042
450	1835
450	80826
450	36515
450	21208
450	85916
450	77047
450	40312
450	98210
450	1987
450	44438
450	53231
450	21945
451	36850
451	20084
451	28832
451	40197
451	21832
451	69700
451	33312
451	53668
451	99934
451	51336
451	23705
451	46895
451	96131
451	93449
451	63744
451	32095
451	12995
451	3298
451	17967
451	81141
451	64344
451	66870
451	68125
452	60304
452	72305
452	10960
452	57058
452	95458
452	81126
452	53863
452	72098
452	90145
452	90951
452	85046
452	45524
452	92939
452	20963
452	54658
452	76440
452	86132
452	15454
452	84524
452	17136
452	26059
452	72611
452	48947
453	39249
453	64104
453	51705
453	91516
453	55727
453	24770
453	64893
453	98373
453	52510
453	39485
453	70006
453	98626
453	4333
453	34118
453	98826
453	47983
453	65327
453	4567
453	62448
453	96711
453	45065
453	42799
453	73175
454	8689
454	44308
454	66310
454	56547
454	72474
454	8049
454	84945
454	1454
454	4397
454	57041
454	91408
454	92121
454	35746
454	47780
454	2525
454	98982
454	16478
454	42392
454	40949
454	80634
454	79720
454	49251
454	79551
455	94060
455	95038
455	53028
455	82458
455	50109
455	22302
455	30381
455	44396
455	34530
455	68929
455	33360
455	35934
455	18210
455	30891
455	21823
455	78654
455	6285
455	50699
455	41357
455	37133
455	87859
455	26126
455	21518
456	37990
456	76960
456	16378
456	4367
456	8069
456	37760
456	70442
456	47801
456	28404
456	95172
456	32279
456	27059
456	28497
456	98693
456	81972
456	88101
456	11629
456	14428
456	21434
456	96343
456	55321
456	6977
456	92000
457	46403
457	39341
457	33059
457	85465
457	68901
457	95482
457	25507
457	40791
457	7371
457	22793
457	39459
457	38928
457	32588
457	56515
457	18094
457	59023
457	23735
457	71962
457	30803
457	47415
457	81872
457	88851
457	28333
458	83904
458	55404
458	57606
458	51100
458	30935
458	37913
458	57948
458	26673
458	26852
458	81950
458	14764
458	24713
458	18604
458	82522
458	78836
458	88680
458	73975
458	63023
458	18379
458	40368
458	75191
458	77979
458	55017
459	80179
459	33677
459	46048
459	10829
459	68662
459	68982
459	14953
459	17662
459	1012
459	20008
459	58094
459	15218
459	65942
459	21784
459	76597
459	78416
459	91038
459	6159
459	38988
459	75452
459	1978
459	548
459	75538
460	73468
460	94009
460	37930
460	65611
460	6967
460	21000
460	60414
460	31160
460	39078
460	38095
460	26472
460	37166
460	92279
460	89889
460	44682
460	38574
460	36316
460	22393
460	22568
460	61943
460	22488
460	61610
460	39008
461	95122
461	61649
461	96457
461	16580
461	51785
461	16139
461	25724
461	47942
461	26616
461	6608
461	47809
461	46519
461	30708
461	7494
461	61550
461	48433
461	40927
461	88939
461	32822
461	85453
461	8539
461	39884
461	15739
462	61793
462	24647
462	64348
462	15314
462	51089
462	56330
462	49097
462	29415
462	71661
462	81297
462	47753
462	51931
462	47597
462	73924
462	89177
462	28010
462	94275
462	78418
462	38283
462	5758
462	64102
462	69284
462	44334
463	46325
463	9988
463	82814
463	94161
463	62393
463	24458
463	97143
463	9596
463	61684
463	27813
463	54713
463	75487
463	49127
463	71652
463	59636
463	77553
463	9704
463	4767
463	84535
463	31553
463	29799
463	31548
463	39460
464	50522
464	71113
464	12548
464	97258
464	87765
464	77238
464	91976
464	18672
464	72039
464	5728
464	88370
464	56817
464	64198
464	15091
464	78640
464	55538
464	7475
464	58476
464	48341
464	36179
464	1212
464	9461
464	92673
465	10014
465	89878
465	78440
465	95196
465	78735
465	92649
465	59138
465	50741
465	30486
465	86087
465	11075
465	91301
465	64372
465	36662
465	53254
465	41944
465	80668
465	46031
465	87316
465	99965
465	88751
465	74058
465	59802
466	64332
466	86560
466	77401
466	35812
466	60374
466	24314
466	47947
466	81723
466	87785
466	89301
466	83079
466	58730
466	78451
466	87492
466	74624
466	82607
466	77133
466	94956
466	36992
466	76435
466	82430
467	66036
467	26798
467	25746
467	84724
467	31275
467	85281
467	58459
467	19610
467	42763
467	7458
467	93057
467	61069
467	82497
467	6224
467	51448
467	81163
467	51943
467	51290
467	78266
467	11711
467	36606
468	41105
468	59568
468	7876
468	80374
468	3906
468	96648
468	35069
468	28528
468	19025
468	44161
468	36065
468	97813
468	95092
468	27120
468	96459
468	96231
468	36636
468	33982
468	24924
468	45538
468	47418
469	89708
469	78876
469	92991
469	68128
469	137
469	24999
469	76437
469	6901
469	3422
469	29031
469	64079
469	97803
469	4625
469	69868
469	15347
469	24913
469	9925
469	46202
469	36367
469	85632
469	40025
470	90789
470	22178
470	16452
470	41187
470	81136
470	77877
470	65975
470	10986
470	84864
470	12357
470	38142
470	34666
470	40412
470	38733
470	47576
470	30706
470	69145
470	45870
470	64295
470	35919
470	55474
471	83750
471	36010
471	94069
471	15903
471	325
471	67928
471	9953
471	30247
471	3224
471	37720
471	96775
471	21565
471	43699
471	24534
471	18006
471	93603
471	9646
471	77881
471	89658
471	39140
471	1321
472	26403
472	32017
472	3183
472	75036
472	4863
472	45480
472	81637
472	25958
472	70239
472	72635
472	26793
472	64
472	38368
472	63892
472	81978
472	44882
472	23859
472	89379
472	3998
472	90240
472	30046
473	54576
473	21392
473	96080
473	59869
473	67377
473	47092
473	39260
473	27479
473	52478
473	15303
473	80216
473	95839
473	66612
473	34124
473	59795
473	80012
473	78246
473	8780
473	54473
473	37178
473	78023
474	17805
474	49475
474	55574
474	90878
474	78180
474	99210
474	33014
474	4310
474	79593
474	72113
474	86882
474	38266
474	84771
474	66855
474	75658
474	82534
474	20246
474	30837
474	46447
474	26643
474	84176
475	64032
475	16304
475	73064
475	40448
475	4339
475	3827
475	31874
475	93696
475	92275
475	36428
475	99179
475	20882
475	53234
475	70528
475	64777
475	93676
475	37915
475	32979
475	3700
475	18004
475	40788
476	59575
476	61084
476	54971
476	82898
476	393
476	46683
476	69129
476	11940
476	57283
476	24335
476	32271
476	83018
476	82057
476	43463
476	41881
476	80895
476	44115
476	19118
476	47827
476	62775
476	51933
477	93339
477	87413
477	23374
477	55990
477	21975
477	79213
477	19498
477	23667
477	67645
477	19149
477	71274
477	98662
477	1517
477	86360
477	9202
477	65033
477	86061
477	69273
477	45537
477	94180
477	53773
478	97038
478	28988
478	96153
478	19575
478	63421
478	76169
478	21807
478	88077
478	96127
478	13512
478	73131
478	43034
478	1735
478	57216
478	96141
478	92164
478	71871
478	89048
478	85229
478	72263
478	70524
479	58533
479	54146
479	74073
479	68132
479	5942
479	29295
479	29694
479	8190
479	9212
479	66982
479	97621
479	1929
479	15475
479	78983
479	820
479	38110
479	95127
479	42222
479	48031
479	88468
479	8692
480	27779
480	40792
480	10056
480	98700
480	94354
480	66882
480	32488
480	96721
480	49071
480	27729
480	56321
480	51033
480	83862
480	29677
480	95194
480	5293
480	71934
480	52228
480	28917
480	16359
480	85779
481	80833
481	26000
481	471
481	64276
481	72568
481	72716
481	92403
481	89510
481	54396
481	62104
481	45187
481	81449
481	37034
481	24266
481	9273
481	12112
481	35525
481	49425
481	76699
481	89236
481	29767
482	96937
482	21116
482	55717
482	41251
482	19453
482	9059
482	70560
482	23484
482	31598
482	12165
482	24983
482	21704
482	59199
482	96340
482	63360
482	52593
482	98016
482	59147
482	83421
482	58383
482	91590
482	9673
482	596
483	60541
483	61051
483	69606
483	96639
483	51894
483	38647
483	42113
483	69019
483	29398
483	14758
483	33570
483	86028
483	29672
483	77063
483	39810
483	18222
483	72244
483	27419
483	58741
483	36870
483	55451
483	69953
483	38424
484	10244
484	12111
484	5392
484	44926
484	36196
484	77068
484	35837
484	97422
484	81067
484	65381
484	84412
484	15064
484	52319
484	9100
484	37275
484	77996
484	93567
484	7864
484	95590
484	73512
484	33434
484	60159
484	84486
485	9658
485	70547
485	92866
485	95269
485	64049
485	53048
485	48955
485	63363
485	72637
485	72011
485	25209
485	10313
485	55762
485	84852
485	21070
485	3735
485	77619
485	35334
485	12533
485	15896
485	17974
485	69919
485	33520
486	80138
486	35118
486	66286
486	68768
486	96934
486	52464
486	74144
486	19478
486	43723
486	75995
486	31839
486	76271
486	63525
486	85929
486	19073
486	74278
486	64096
486	34727
486	55809
486	3146
486	15457
486	78276
486	94434
487	41422
487	9441
487	32798
487	87449
487	41758
487	70650
487	86524
487	54013
487	54042
487	87008
487	37239
487	11275
487	93619
487	47180
487	68649
487	86499
487	43410
487	2974
487	62621
487	50663
487	37372
487	94095
487	94551
488	36230
488	44116
488	93209
488	75443
488	89372
488	99407
488	88732
488	65896
488	61703
488	53452
488	67012
488	97635
488	6117
488	86625
488	10830
488	28726
488	48783
488	48455
488	81999
488	72737
488	47974
488	5805
488	44581
489	89601
489	9990
489	75764
489	16376
489	94202
489	41671
489	30014
489	41001
489	89582
489	65631
489	36808
489	98429
489	3193
489	31755
489	74480
489	92626
489	49014
489	21890
489	65016
489	22391
489	74494
489	8708
489	47836
490	94838
490	78745
490	92771
490	1505
490	76077
490	66228
490	95402
490	76705
490	77705
490	89392
490	83216
490	27327
490	66638
490	99957
490	1538
490	86404
490	12476
490	61178
490	73564
490	14499
490	1068
490	2080
490	77916
491	81392
491	65320
491	4808
491	52458
491	11767
491	97912
491	57722
491	39550
491	70812
491	99590
491	74906
491	24906
491	85499
491	21246
491	81779
491	26483
491	24978
491	88896
491	88814
491	16119
491	11307
491	71361
491	51981
492	85818
492	65425
492	52946
492	93884
492	8916
492	56297
492	65979
492	2932
492	65367
492	29491
492	97008
492	2919
492	33855
492	79215
492	77789
492	44463
492	25745
492	13265
492	39138
492	7670
492	91294
492	15665
492	25428
493	93941
493	72804
493	52676
493	43280
493	73520
493	33117
493	55935
493	42534
493	33089
493	39602
493	79710
493	15123
493	75912
493	1933
493	65206
493	49265
493	73513
493	57715
493	5227
493	31812
493	29870
493	94877
493	13321
494	64443
494	43764
494	94649
494	62157
494	56280
494	20585
494	39063
494	65534
494	6678
494	99967
494	50943
494	87661
494	31138
494	8169
494	36639
494	6851
494	95616
494	70595
494	21553
494	22075
494	48443
494	7038
494	36400
495	30711
495	43350
495	72916
495	42326
495	71633
495	67867
495	79882
495	84312
495	89750
495	35408
495	90908
495	98143
495	8834
495	4964
495	69530
495	1560
495	67129
495	7870
495	17509
495	21776
495	91114
495	45182
495	30652
496	19408
496	97775
496	36126
496	54036
496	81447
496	13029
496	43400
496	12818
496	46979
496	36287
496	27787
496	41334
496	28154
496	21524
496	46023
496	18599
496	2328
496	39356
496	63673
496	4224
496	67414
496	27707
496	42177
497	40630
497	43176
497	38556
497	4420
497	12805
497	63370
497	48310
497	89904
497	66316
497	1945
497	50641
497	84116
497	31765
497	67189
497	20971
497	24689
497	96497
497	24388
497	93750
497	39956
497	6024
497	31813
497	5368
498	1064
498	96319
498	64835
498	23816
498	47188
498	10140
498	58348
498	91614
498	97050
498	17698
498	28140
498	34712
498	83726
498	75292
498	5210
498	68693
498	56893
498	64903
498	11436
498	59823
498	52378
498	30845
498	89305
499	19564
499	53363
499	31125
499	74155
499	82662
499	33029
499	57482
499	15185
499	73160
499	5369
499	67290
499	93287
499	38682
499	93922
499	53060
499	86511
499	34878
499	93059
499	29674
499	30748
499	64512
499	81025
499	36601
500	37948
500	82213
500	75785
500	19512
500	94570
500	59901
500	111
500	5990
500	98775
500	53957
500	70046
500	13053
500	41304
500	20969
500	23272
500	85324
500	82861
500	15489
500	82054
500	7353
500	84406
500	32139
500	94249
501	11392
501	67615
501	92874
501	99163
501	32717
501	35850
501	75462
501	37848
501	16785
501	4221
501	39774
501	60016
501	60769
501	1292
501	26539
501	65802
501	1078
501	61270
501	57248
501	73649
501	99537
501	25985
501	43029
502	30753
502	65804
502	8544
502	25398
502	48968
502	23169
502	42905
502	31976
502	19801
502	33586
502	99466
502	84532
502	20974
502	7076
502	10731
502	25845
502	43440
502	75959
502	44934
502	54100
502	33115
502	55416
502	89713
503	53272
503	35179
503	62769
503	33175
503	26303
503	27263
503	61292
503	42018
503	84807
503	36964
503	75667
503	28762
503	90491
503	70237
503	85824
503	41027
503	91793
503	23371
503	81377
503	53076
503	56398
503	89321
503	66906
504	5120
504	11191
504	97434
504	44763
504	3287
504	42911
504	10063
504	36687
504	57865
504	77047
504	75041
504	94928
504	80826
504	36515
504	21208
504	29705
504	11638
504	40312
504	83642
504	77419
504	77489
504	1835
504	22756
505	68395
505	21798
505	70280
505	69329
505	39861
505	53668
505	21790
505	93667
505	99934
505	51336
505	23705
505	26380
505	91472
505	70414
505	33312
505	27533
505	62029
505	20877
505	64344
505	85698
505	27540
505	32095
505	42745
506	39249
506	64104
506	28119
506	94823
506	22192
506	40374
506	19591
506	70006
506	95567
506	1164
506	26900
506	37901
506	79048
506	14952
506	78347
506	47983
506	94774
506	66596
506	97867
506	15097
506	53035
506	98806
506	3886
507	37990
507	76960
507	81972
507	98693
507	92000
507	44689
507	70442
507	89743
507	14428
507	23990
507	20926
507	72028
507	55321
507	5377
507	82734
507	88101
507	78296
507	25600
507	75772
507	11629
507	17971
507	27059
507	83900
508	95453
508	21554
508	83934
508	79763
508	36787
508	12197
508	76640
508	30808
508	67113
508	69896
508	89971
508	3044
508	11462
508	31094
508	1665
508	85559
508	27894
508	51786
508	6356
508	8275
508	73380
508	98872
508	63644
509	88939
509	19142
509	13271
509	28296
509	7259
509	9632
509	16139
509	3869
509	77335
509	6608
509	71308
509	64718
509	47440
509	29447
509	71373
509	48433
509	40927
509	15736
509	3922
509	55453
509	42523
509	16489
509	18963
510	61793
510	24647
510	64348
510	5758
510	35157
510	56330
510	49097
510	29415
510	71661
510	81297
510	78418
510	52217
510	47597
510	73924
510	89177
510	28010
510	37294
510	1416
510	2231
510	98074
510	64102
510	60716
510	44334
511	46325
511	9988
511	9704
511	94161
511	62393
511	95507
511	97143
511	9596
511	7180
511	77224
511	54713
511	63312
511	43367
511	875
511	35818
511	77553
511	36686
511	51579
511	7453
511	25758
511	90361
511	25131
511	39460
512	50522
512	95273
512	20244
512	97258
512	95009
512	41262
512	91976
512	18672
512	1169
512	24300
512	9053
512	58476
512	10072
512	41052
512	45750
512	91438
512	7475
512	78024
512	51653
512	31173
512	98378
512	78113
512	71933
513	10014
513	89878
513	78440
513	95196
513	78735
513	11075
513	14180
513	94155
513	30486
513	86087
513	25776
513	18230
513	65659
513	36662
513	53254
513	41944
513	80668
513	79723
513	20051
513	21702
513	59138
513	74058
513	59802
514	94956
514	76518
514	26438
514	35812
514	60374
514	89301
514	28164
514	81723
514	87785
514	58730
514	83079
514	36992
514	78451
514	27559
514	29422
514	39150
514	77133
514	64332
514	81599
514	76435
514	11976
514	95346
514	83314
515	69429
515	6224
515	83758
515	23163
515	53274
515	60585
515	42763
515	62964
515	91993
515	7458
515	93057
515	61069
515	35462
515	96310
515	18602
515	4136
515	85281
515	11773
515	26798
515	19610
515	38186
515	53133
515	3553
516	39837
516	22573
516	69986
516	30264
516	12298
516	27272
516	24905
516	1302
516	43002
516	95451
516	59141
516	36793
516	35045
516	58512
516	80017
516	91402
516	18928
516	62839
516	45630
516	83450
516	36719
516	30621
516	49063
517	33982
517	59568
517	60142
517	80374
517	3906
517	96648
517	35069
517	28528
517	31118
517	68495
517	36065
517	97813
517	95092
517	27120
517	97105
517	96231
517	3895
517	43516
517	16470
517	45538
517	47418
517	67881
517	41105
518	89223
518	97958
518	66822
518	27970
518	66124
518	51360
518	14918
518	13961
518	40014
518	33435
518	26515
518	50707
518	54562
518	17273
518	54615
518	89089
518	12565
518	20162
518	99247
518	98819
518	59654
518	58856
518	89921
519	19392
519	19996
519	92991
519	68128
519	72076
519	24999
519	9925
519	28594
519	85632
519	29031
519	76437
519	97803
519	28701
519	137
519	15347
519	24913
519	41243
519	29954
519	34188
519	65458
519	17370
519	9774
519	1092
520	22795
520	87484
520	19744
520	74292
520	49906
520	1384
520	83648
520	10868
520	54445
520	90891
520	8309
520	99437
520	33626
520	86294
520	92744
520	32687
520	87850
520	8652
520	13574
520	52241
520	20075
520	86097
520	97070
521	62261
521	24375
521	72265
521	33203
521	63919
521	18236
521	86830
521	28880
521	86541
521	54239
521	32204
521	70975
521	46613
521	4586
521	78692
521	16218
521	74308
521	17523
521	62444
521	86883
521	63107
521	25118
521	82637
522	90789
522	22178
522	35919
522	10986
522	30706
522	69145
522	17951
522	41187
522	38733
522	34666
522	76594
522	23779
522	55474
522	38788
522	77877
522	73084
522	15279
522	96810
522	57382
522	98538
522	78748
522	61922
522	84864
523	26403
523	32017
523	3183
523	75036
523	86196
523	64050
523	15484
523	29761
523	70239
523	72635
523	13090
523	64
523	68484
523	63892
523	81978
523	12977
523	23859
523	89379
523	75169
523	15353
523	96957
523	14916
523	8612
524	54576
524	21392
524	96080
524	32680
524	67377
524	47092
524	39260
524	32037
524	27576
524	84273
524	30564
524	78023
524	66612
524	59869
524	83981
524	17418
524	23193
524	80216
524	27184
524	37178
524	25439
524	35449
524	29896
525	14561
525	52652
525	87303
525	24039
525	29325
525	97929
525	26592
525	77510
525	64825
525	26065
525	39616
525	97884
525	28307
525	6222
525	83359
525	54977
525	12080
525	43472
525	95918
525	69358
525	75197
525	85546
525	6228
526	38266
526	49475
526	55574
526	90878
526	75658
526	99210
526	33014
526	4310
526	79593
526	72113
526	86882
526	66855
526	84771
526	82534
526	34571
526	26643
526	20246
526	84176
526	66148
526	58036
526	93312
526	10268
526	38281
527	18004
527	16304
527	83
527	40448
527	91979
527	13965
527	99179
527	37915
527	93676
527	40788
527	3700
527	20882
527	61340
527	37293
527	59103
527	70528
527	32979
527	61373
527	33628
527	34363
527	50449
527	33442
527	64086
528	76328
528	3702
528	13594
528	97745
528	36297
528	53833
528	83474
528	12051
528	69967
528	70845
528	336
528	73591
528	94893
528	52192
528	63236
528	47320
528	4527
528	73711
528	98141
528	52476
528	46894
528	30342
528	71273
529	51933
529	61084
529	54971
529	82898
529	393
529	44826
529	69129
529	26444
529	57283
529	24335
529	32271
529	83018
529	82057
529	19118
529	5868
529	80895
529	44115
529	33611
529	58749
529	94989
529	14580
529	41881
529	34428
530	93339
530	54462
530	23374
530	55990
530	21975
530	9202
530	33779
530	59598
530	67645
530	88673
530	84505
530	43499
530	22604
530	62439
530	92381
530	49049
530	86061
530	45550
530	9158
530	90856
530	95601
530	17938
530	9501
531	58533
531	85744
531	5942
531	78983
531	67898
531	74073
531	29694
531	70069
531	9212
531	71462
531	54146
531	66369
531	79740
531	9339
531	40880
531	38110
531	95127
531	75265
531	29295
531	48031
531	20831
531	89817
531	32235
532	64083
532	70687
532	96637
532	77758
532	11539
532	73479
532	83266
532	35864
532	40778
532	8264
532	49393
532	57457
532	80717
532	68960
532	61973
532	46735
532	43720
532	16593
532	78430
532	58271
532	46793
532	39704
532	97215
533	20973
533	70737
533	47865
533	41819
533	62127
533	65568
533	55768
533	43292
533	37281
533	90837
533	36051
533	84365
533	92234
533	10289
533	16259
533	5213
533	57894
533	62805
533	60401
533	79226
533	68406
533	19347
533	1567
534	27779
534	40792
534	10056
534	62801
534	52228
534	66882
534	71934
534	96721
534	90086
534	27729
534	3180
534	8987
534	88969
534	2921
534	95194
534	83862
534	94354
534	16575
534	1096
534	32524
534	99096
534	10653
534	76903
535	47686
535	16182
535	6149
535	94332
535	47527
535	84754
535	15441
535	63976
535	97288
535	61487
535	53368
535	6268
535	96874
535	86179
535	7698
535	28291
535	38433
535	43224
535	25824
535	84810
535	96558
535	26247
535	67107
536	87745
536	27270
536	5007
536	8487
536	50085
536	2347
536	53921
536	75728
536	26203
536	61491
536	67549
536	14339
536	42972
536	34796
536	92650
536	65800
536	23964
536	62941
536	69603
536	50304
536	88523
536	77946
536	78623
537	80833
537	52843
537	471
537	64276
537	72568
537	39779
537	92403
537	89510
537	54396
537	62104
537	45187
537	81449
537	37034
537	96028
537	9273
537	69030
537	35525
537	32811
537	65433
537	89236
537	12946
537	74823
537	79931
538	18444
538	32508
538	35173
538	64424
538	38647
538	981
538	66433
538	73712
538	29398
538	14758
538	42113
538	39788
538	95278
538	77063
538	69019
538	18222
538	49114
538	22992
538	36870
538	16352
538	28151
538	85116
538	17853
539	10244
539	59727
539	61767
539	44926
539	36196
539	58540
539	35837
539	33434
539	61256
539	45528
539	91329
539	84536
539	95847
539	20087
539	37275
539	51118
539	10167
539	11675
539	87852
539	83849
539	83198
539	34822
539	45548
540	9658
540	70547
540	92866
540	95269
540	64049
540	53048
540	48955
540	63363
540	72637
540	72011
540	6338
540	10313
540	88715
540	84852
540	22930
540	74337
540	47906
540	15896
540	12533
540	85472
540	13975
540	69919
540	73834
541	21531
541	32798
541	84301
541	77556
541	2305
541	65498
541	17082
541	49997
541	92004
541	87008
541	37171
541	70650
541	76060
541	40137
541	54013
541	66815
541	41758
541	74941
541	62621
541	37877
541	87266
541	97493
541	89248
542	94838
542	78745
542	26542
542	1505
542	17988
542	66228
542	12476
542	76705
542	74655
542	89392
542	83216
542	27327
542	43196
542	16245
542	7807
542	61424
542	7796
542	37614
542	59950
542	14499
542	75090
542	29212
542	38594
543	81392
543	65320
543	4808
543	63865
543	11767
543	97912
543	57722
543	10740
543	781
543	99590
543	58669
543	70812
543	42644
543	7614
543	71100
543	26483
543	24978
543	88896
543	37984
543	33347
543	11307
543	71751
543	92476
544	99988
544	65425
544	86004
544	93884
544	8916
544	56297
544	65979
544	7670
544	65182
544	29491
544	79215
544	89113
544	65146
544	57763
544	57922
544	12763
544	25745
544	44463
544	77789
544	14891
544	91294
544	89420
544	25428
545	58755
545	71525
545	3748
545	14988
545	9856
545	18923
545	93951
545	57615
545	67216
545	50104
545	85579
545	72592
545	61976
545	44386
545	65946
545	28357
545	11588
545	79590
545	60880
545	8442
545	29053
545	35930
545	18907
546	32448
546	83293
546	49004
546	13030
546	50801
546	81689
546	44093
546	77754
546	37703
546	75890
546	24653
546	2028
546	29161
546	91291
546	41789
546	49027
546	60871
546	96547
546	74320
546	8628
546	82223
546	99805
546	86080
547	70618
547	74071
547	48480
547	31219
547	92628
547	2465
547	63620
547	8169
547	58924
547	21553
547	74242
547	25937
547	38372
547	50943
547	56280
547	6851
547	16053
547	9246
547	59837
547	83363
547	84745
547	5318
547	89070
548	30711
548	60652
548	17174
548	42326
548	67297
548	17509
548	90908
548	7153
548	89750
548	64077
548	97778
548	54461
548	98287
548	4964
548	69451
548	69594
548	40789
548	20754
548	73306
548	71285
548	84424
548	71816
548	81466
549	19408
549	69785
549	77118
549	36126
549	81447
549	13029
549	21524
549	39356
549	19339
549	12818
549	94447
549	81947
549	28154
549	79409
549	48737
549	51201
549	4224
549	30316
549	62162
549	50679
549	8896
549	3367
549	78594
550	37032
550	27331
550	68348
550	69192
550	82839
550	13758
550	3161
550	90675
550	73258
550	83367
550	70085
550	93803
550	77257
550	45419
550	9507
550	5450
550	58772
550	28803
550	38514
550	7013
550	48976
550	31941
550	2559
551	20998
551	4541
551	75785
551	98747
551	74098
551	95374
551	111
551	29864
551	60139
551	53957
551	24531
551	29185
551	26022
551	87786
551	23272
551	85324
551	85860
551	98775
551	15905
551	9113
551	84406
551	80505
551	47137
552	53272
552	28595
552	46176
552	33175
552	26303
552	53282
552	99817
552	54138
552	84807
552	36964
552	2595
552	11411
552	36278
552	89984
552	23371
552	41027
552	91793
552	82154
552	56398
552	76596
552	62769
552	89321
552	20127
553	5120
553	76750
553	1730
553	44763
553	64299
553	9951
553	10063
553	36687
553	57865
553	77047
553	68042
553	94928
553	80826
553	36515
553	21208
553	42911
553	96694
553	40312
553	83642
553	77419
553	26546
553	24705
553	80088
554	50688
554	45288
554	54550
554	99089
554	53270
554	26068
554	70715
554	62364
554	46107
554	64125
554	46039
554	15566
554	15199
554	46553
554	58822
554	37696
554	98153
554	87199
554	42517
554	60872
554	71023
554	88869
554	54137
555	51723
555	1347
555	45065
555	61893
555	15870
555	65978
555	19591
555	62455
555	14651
555	1164
555	26900
555	75724
555	55236
555	8253
555	33715
555	83020
555	94774
555	40578
555	40341
555	27669
555	12630
555	98806
555	7594
556	77521
556	72819
556	53385
556	91455
556	2886
556	32575
556	76850
556	10561
556	78106
556	9945
556	6696
556	91983
556	77892
556	48670
556	44505
556	52444
556	22016
556	3144
556	67176
556	24760
556	34448
556	80905
556	76368
557	83518
557	86020
557	2351
557	56647
557	36397
557	53701
557	88592
557	4154
557	29117
557	70132
557	16977
557	1594
557	82532
557	96067
557	70241
557	77391
557	47833
557	39610
557	61528
557	5862
557	9633
557	23264
557	59720
558	31606
558	70794
558	61813
558	40820
558	10172
558	57157
558	12381
558	64111
558	549
558	45449
558	64261
558	40292
558	19545
558	65144
558	29046
558	57494
558	27417
558	42160
558	32165
558	32858
558	9584
558	57476
558	23468
559	72028
559	76960
559	81972
559	99900
559	67578
559	18665
559	70442
559	89743
559	33280
559	31133
559	34205
559	93586
559	10712
559	44689
559	35081
559	39584
559	65199
559	63951
559	521
559	95670
559	46272
559	27059
559	72710
560	95453
560	17872
560	82792
560	79763
560	36787
560	43675
560	17415
560	20571
560	69896
560	18383
560	5922
560	37265
560	47851
560	11462
560	11064
560	23559
560	22778
560	51786
560	6356
560	33785
560	20163
560	37840
560	64597
561	61496
561	91707
561	95345
561	87284
561	31004
561	94422
561	93688
561	23568
561	84563
561	83734
561	4434
561	91268
561	45457
561	99177
561	82537
561	77853
561	66636
561	70583
561	24301
561	36522
561	40442
561	85438
561	30394
562	44035
562	93828
562	47321
562	29883
562	40621
562	91655
562	38799
562	55140
562	29136
562	79299
562	51960
562	55298
562	12707
562	94596
562	22102
562	17986
562	15988
562	37935
562	23774
562	44044
562	35711
562	57411
562	53694
563	46403
563	39341
563	54492
563	44932
563	75924
563	95482
563	58363
563	40618
563	85696
563	33390
563	33059
563	35773
563	30283
563	12935
563	57535
563	89573
563	80738
563	79900
563	62033
563	27744
563	66184
563	45505
563	72770
564	42523
564	64718
564	51199
564	26051
564	18598
564	16489
564	77335
564	9338
564	15736
564	2947
564	58692
564	2609
564	47440
564	91889
564	64292
564	48433
564	93920
564	34018
564	7259
564	37612
564	29757
564	26566
564	4157
565	52217
565	71071
565	64348
565	15848
565	28010
565	56330
565	52837
565	37294
565	339
565	92520
565	97275
565	76837
565	51443
565	60716
565	89177
565	11593
565	60554
565	1416
565	2231
565	9400
565	64102
565	52418
565	44334
566	26943
566	29833
566	31431
566	34998
566	90129
566	30993
566	74946
566	20019
566	82967
566	4686
566	89934
566	46890
566	19366
566	42015
566	15887
566	28801
566	78477
566	46506
566	24357
566	10221
566	73907
566	8312
566	8714
567	63312
567	9988
567	67914
567	19193
567	23925
567	95507
567	19075
567	68060
567	7180
567	77224
567	54713
567	1729
567	43367
567	71840
567	35818
567	77553
567	83560
567	36686
567	7453
567	25758
567	90361
567	25131
567	39460
568	55710
568	62629
568	3191
568	81706
568	88818
568	96029
568	14196
568	94563
568	75361
568	42223
568	11879
568	38981
568	90867
568	21962
568	12859
568	25989
568	47815
568	77301
568	2778
568	9569
568	39664
568	57303
568	69793
569	10014
569	65659
569	78440
569	78932
569	13847
569	58791
569	14180
569	85532
569	30486
569	62594
569	25776
569	46020
569	39902
569	47386
569	46785
569	41944
569	83211
569	70671
569	20051
569	33500
569	59138
569	74058
569	59802
570	19263
570	7642
570	75744
570	55287
570	6775
570	97512
570	58375
570	45264
570	70181
570	89102
570	15565
570	7960
570	54801
570	30464
570	5215
570	14114
570	17521
570	65068
570	23167
570	75102
570	69102
570	38768
570	58308
571	94956
571	58909
571	23508
571	35812
571	95706
571	36494
571	28164
571	81723
571	87785
571	58730
571	83079
571	6221
571	78451
571	27559
571	74493
571	39150
571	25968
571	11976
571	81599
571	76435
571	60982
571	33399
571	86560
572	61069
572	35462
572	96976
572	18602
572	62964
572	60585
572	91993
572	19610
572	34305
572	7458
572	93057
572	9384
572	84606
572	78371
572	49703
572	42763
572	53274
572	13960
572	95343
572	11773
572	83758
572	3553
572	84502
573	39837
573	22573
573	69986
573	30264
573	12298
573	10691
573	24905
573	1302
573	43002
573	95451
573	59141
573	36793
573	64407
573	58512
573	80017
573	50711
573	18928
573	62839
573	96889
573	83450
573	82188
573	84073
573	11758
574	47418
574	97105
574	60142
574	35887
574	71404
574	68361
574	15733
574	56274
574	54415
574	67881
574	36065
574	97813
574	95092
574	94074
574	26193
574	48464
574	3895
574	63984
574	16470
574	57858
574	20435
574	15991
574	89067
575	63450
575	37018
575	18316
575	55571
575	19507
575	35338
575	11345
575	77951
575	93835
575	9681
575	39388
575	81462
575	83621
575	95101
575	36548
575	40766
575	41132
575	71609
575	27240
575	1247
575	6087
575	10126
575	13952
576	9049
576	97958
576	56033
576	89089
576	66124
576	20162
576	26515
576	27970
576	44771
576	33435
576	40014
576	29138
576	4204
576	2184
576	58097
576	45842
576	12565
576	81118
576	99247
576	98819
576	27178
576	75216
576	80652
577	90789
577	23779
577	38788
577	20638
577	30706
577	42847
577	62542
577	41187
577	57382
577	61922
577	96810
577	60046
577	78748
577	71247
577	25548
577	76594
577	6258
577	84864
577	55143
577	34666
577	69367
577	41857
577	23605
578	54578
578	46773
578	32017
578	16125
578	82432
578	64050
578	22001
578	89699
578	70239
578	14916
578	68484
578	56864
578	44380
578	71185
578	81978
578	12977
578	23859
578	79996
578	75169
578	65933
578	68800
578	47772
578	17184
579	78023
579	16505
579	88232
579	32680
579	58658
579	70499
579	25269
579	37178
579	25113
579	84273
579	80216
579	25439
579	29896
579	29496
579	91637
579	2802
579	59795
579	17418
579	51855
579	83353
579	7343
579	85891
579	25793
580	22236
580	51292
580	55953
580	33581
580	2903
580	14034
580	31008
580	80703
580	26735
580	49416
580	47343
580	35550
580	94445
580	89389
580	83704
580	67555
580	89652
580	62883
580	21343
580	86989
580	34581
580	44980
580	91740
581	66845
581	1019
581	18051
581	93187
581	81939
581	24113
581	18193
581	32999
581	57962
581	5768
581	52873
581	57799
581	74959
581	87532
581	47069
581	72963
581	32663
581	76996
581	16488
581	80618
581	24941
581	76650
581	66224
582	31788
582	84771
582	75658
582	90878
582	50809
582	42768
582	44627
582	26643
582	34571
582	99210
582	84768
582	49873
582	95935
582	12315
582	63894
582	16222
582	45582
582	14314
582	69786
582	1320
582	74836
582	54839
582	14621
583	47320
583	3702
583	13594
583	63236
583	91488
583	53833
583	30342
583	12051
583	69967
583	70845
583	336
583	85842
583	83256
583	96101
583	79057
583	8372
583	4880
583	77151
583	52476
583	94893
583	82354
583	21421
583	76328
584	51933
584	61084
584	54971
584	33611
584	76331
584	44826
584	69129
584	393
584	41881
584	80895
584	24335
584	83018
584	82057
584	19118
584	33543
584	82898
584	44115
584	89867
584	3449
584	94989
584	79424
584	24097
584	47156
585	65033
585	63064
585	23374
585	9501
585	21975
585	62439
585	93238
585	59598
585	67645
585	19149
585	44672
585	64606
585	22604
585	86360
585	30731
585	28304
585	86061
585	43499
585	25251
585	76647
585	53773
585	85488
585	1517
586	58533
586	79740
586	85744
586	57821
586	48596
586	74073
586	38110
586	22963
586	9212
586	22811
586	67898
586	32235
586	63803
586	56682
586	12306
586	77652
586	29295
586	82215
586	44649
586	48031
586	77852
586	88386
586	91984
587	76817
587	4980
587	25596
587	4543
587	86688
587	6994
587	93076
587	7522
587	16255
587	24104
587	56744
587	91493
587	98441
587	77204
587	35487
587	25443
587	24424
587	91406
587	90678
587	92690
587	14478
587	39315
587	10240
588	7569
588	11369
588	11968
588	45038
588	13569
588	97934
588	51606
588	20364
588	47455
588	65355
588	46109
588	55720
588	24675
588	14454
588	28995
588	92858
588	19745
588	75054
588	27801
588	88898
588	79237
588	16808
588	51920
589	34923
589	70687
589	12406
589	73479
589	11539
589	96637
589	23175
589	35864
589	86842
589	8264
589	49393
589	46735
589	56762
589	32041
589	41848
589	53137
589	97215
589	70854
589	39704
589	58271
589	41156
589	47230
589	84114
590	92234
590	70737
590	89115
590	79226
590	5213
590	10289
590	84365
590	62805
590	19703
590	90837
590	68406
590	16202
590	1567
590	65568
590	16259
590	75163
590	22924
590	71200
590	19347
590	25615
590	84258
590	14224
590	47065
591	27779
591	7053
591	10056
591	56701
591	52228
591	76573
591	93553
591	48545
591	90086
591	27729
591	62190
591	96469
591	2921
591	84995
591	24130
591	89508
591	94354
591	99138
591	33464
591	28884
591	25946
591	10653
591	76903
592	87745
592	46356
592	5007
592	8487
592	50085
592	2347
592	53921
592	98000
592	26203
592	61491
592	49535
592	14339
592	42972
592	40231
592	74376
592	65800
592	69603
592	77946
592	23511
592	50304
592	88523
592	23564
592	34799
593	12946
593	6125
593	59472
593	64276
593	72568
593	96028
593	97292
593	65433
593	46428
593	62104
593	45187
593	71623
593	37034
593	41858
593	9273
593	65982
593	35525
593	32811
593	91711
593	98384
593	3657
593	66473
593	79931
594	39788
594	652
594	35173
594	91431
594	27582
594	29298
594	37314
594	73712
594	19776
594	14758
594	42113
594	36188
594	79650
594	40147
594	92353
594	56659
594	10231
594	3265
594	49114
594	71343
594	28151
594	81505
594	13162
594	10739
594	23070
594	84430
595	10244
595	59727
595	9062
595	88273
595	24134
595	34915
595	35837
595	97422
595	20087
595	82945
595	61979
595	30596
595	95847
595	51406
595	91029
595	51118
595	64249
595	11675
595	89217
595	68599
595	5864
595	34822
595	82010
595	53409
595	67089
595	27035
596	9658
596	70547
596	75820
596	61413
596	64049
596	53048
596	48955
596	47906
596	72637
596	72011
596	6338
596	10313
596	88715
596	84852
596	22930
596	74337
596	95312
596	21652
596	73834
596	81997
596	56069
596	61810
596	13975
596	70691
596	29578
596	56669
597	21531
597	40137
597	32798
597	76060
597	2305
597	97698
597	5164
597	74941
597	68016
597	87008
597	83169
597	66020
597	9441
597	55590
597	77071
597	26953
597	74688
597	92004
597	37860
597	92812
597	6446
597	42740
597	89248
597	14060
597	15197
597	70483
598	22927
598	32773
598	93209
598	74894
598	36707
598	27913
598	68058
598	38355
598	39239
598	53452
598	51549
598	20259
598	6117
598	63923
598	29115
598	70357
598	80930
598	34633
598	47677
598	39394
598	59303
598	62618
598	67127
598	2759
598	55367
598	25904
599	94317
599	12635
599	55821
599	31806
599	89710
599	65386
599	28794
599	32574
599	58061
599	35706
599	96259
599	83822
599	3472
599	72399
599	85670
599	61949
599	1925
599	46263
599	46358
599	48340
599	27541
599	42390
599	809
599	49915
599	21099
599	71727
600	81392
600	57150
600	65777
600	80986
600	11767
600	97912
600	2556
600	10740
600	9889
600	99590
600	58669
600	70812
600	12179
600	32622
600	71100
600	39281
600	24978
600	3616
600	37984
600	44957
600	1994
600	37189
600	81142
600	23993
600	14872
600	22631
601	99988
601	91350
601	95766
601	93884
601	1196
601	56297
601	64353
601	7670
601	65182
601	29491
601	79215
601	32870
601	22160
601	31643
601	89948
601	46461
601	99461
601	26942
601	84190
601	58420
601	91294
601	16484
601	94815
601	57417
601	67668
601	86466
602	58755
602	43705
602	49454
602	14988
602	39995
602	18923
602	26593
602	57615
602	85579
602	50104
602	82313
602	72592
602	82877
602	57782
602	56182
602	7304
602	11588
602	93781
602	59609
602	8442
602	29053
602	35930
602	98199
602	76468
602	70516
602	92135
603	56347
603	96347
603	29713
603	22286
603	75628
603	49934
603	52697
603	13321
603	16576
603	34543
603	44851
603	39347
603	75912
603	6545
603	11495
603	78091
603	62543
603	4237
603	13973
603	56839
603	28364
603	94877
603	82216
603	69217
603	73694
603	2839
604	70618
604	74071
604	36400
604	84787
604	92628
604	2465
604	21153
604	8169
604	58924
604	21553
604	59837
604	25937
604	89070
604	43567
604	31219
604	76287
604	76842
604	5318
604	90012
604	10501
604	50034
604	15674
604	62368
604	22844
604	95181
604	46540
605	30711
605	60652
605	91324
605	42326
605	78484
605	32431
605	90908
605	54517
605	89750
605	64077
605	97778
605	92987
605	23304
605	57401
605	465
605	69594
605	7089
605	3945
605	35408
605	6614
605	84424
605	9867
605	81466
605	86920
605	80996
605	13613
606	19408
606	51201
606	20804
606	36126
606	11933
606	30316
606	77743
606	79409
606	46246
606	75989
606	63673
606	81947
606	28154
606	47182
606	48737
606	89863
606	50679
606	18188
606	39464
606	63385
606	8896
606	3367
606	71859
606	5901
606	69200
606	4137
607	51990
607	12913
607	8359
607	50142
607	7875
607	70145
607	62854
607	92252
607	31765
607	1945
607	72363
607	16148
607	13639
607	28517
607	9991
607	36638
607	94579
607	82956
607	53967
607	23821
607	21820
607	33325
607	59808
607	20467
607	14179
607	36105
608	20998
608	84382
608	75785
608	97838
608	74098
608	95374
608	98775
608	29864
608	85860
608	53957
608	24531
608	17784
608	74612
608	87786
608	98747
608	4541
608	45653
608	68842
608	15905
608	9113
608	42215
608	80505
608	47137
608	28492
608	62858
609	53272
609	45981
609	77382
609	35225
609	26303
609	53282
609	99817
609	58907
609	22633
609	5559
609	39942
609	66906
609	75751
609	86909
609	62952
609	68429
609	82447
609	46913
609	56398
609	44328
609	57586
609	89321
609	77827
609	64056
609	30206
609	41902
610	94928
610	38529
610	36212
610	26546
610	9877
610	96510
610	26412
610	19618
610	57865
610	64182
610	51689
610	96662
610	80826
610	64299
610	21208
610	42911
610	95198
610	40312
610	24062
610	49482
610	81433
610	24705
610	80088
610	49806
610	73491
610	9058
611	50688
611	45288
611	9614
611	71023
611	47490
611	26068
611	70715
611	40619
611	90423
611	94093
611	5265
611	15566
611	87409
611	48295
611	23330
611	21052
611	59033
611	14026
611	42517
611	52013
611	5216
611	88869
611	80656
611	597
611	91543
611	86644
612	18921
612	74111
612	73572
612	56029
612	64438
612	70280
612	44799
612	28911
612	64551
612	27540
612	10326
612	57903
612	15282
612	42078
612	55965
612	78630
612	39861
612	57087
612	95036
612	35705
612	17688
612	97615
612	82000
612	95763
612	34458
612	70227
613	31606
613	17099
613	61813
613	76995
613	10172
613	14593
613	12381
613	44699
613	549
613	45449
613	64261
613	17943
613	83610
613	44780
613	29046
613	85630
613	31085
613	42160
613	65512
613	32165
613	40498
613	90913
613	11013
613	23437
613	42168
613	2071
614	72028
614	41603
614	81972
614	10712
614	67578
614	46583
614	70442
614	39584
614	33280
614	34205
614	17931
614	85204
614	98929
614	44689
614	27349
614	89266
614	31133
614	22983
614	87003
614	16736
614	5304
614	54827
614	57759
614	5289
614	78787
614	41647
615	70879
615	52
615	1258
615	90689
615	42663
615	97800
615	57100
615	51678
615	17048
615	38732
615	47319
615	95754
615	32949
615	33804
615	15161
615	12810
615	1077
615	54495
615	1930
615	43921
615	75618
615	28811
615	63532
615	93316
615	22110
615	26637
616	6659
616	6789
616	20388
616	12335
616	87284
616	94422
616	93688
616	20216
616	89845
616	70583
616	37308
616	8125
616	45457
616	99177
616	45413
616	87569
616	93173
616	76864
616	84563
616	45581
616	85438
616	67035
616	91268
616	10907
616	40487
616	6750
617	99821
617	11718
617	47321
617	90626
617	40621
617	96697
617	86937
617	55140
617	33622
617	66635
617	61416
617	86095
617	33958
617	54506
617	9292
617	45399
617	76835
617	37935
617	27280
617	88928
617	55298
617	77769
617	53694
617	92891
617	37001
617	45280
618	72770
618	98435
618	55665
618	57535
618	30283
618	89598
618	79900
618	24610
618	85696
618	33390
618	62033
618	35773
618	19069
618	58363
618	70515
618	78056
618	80738
618	63293
618	9530
618	27744
618	79754
618	54211
618	24245
618	67641
618	82143
618	89573
619	42523
619	88529
619	82889
619	14360
619	64292
619	67516
619	77335
619	32599
619	87169
619	93920
619	58692
619	49090
619	61172
619	91889
619	7233
619	92710
619	10357
619	87514
619	7259
619	57511
619	4157
619	88360
619	66969
619	5917
619	94500
619	97485
620	92513
620	60716
620	37420
620	16333
620	28010
620	86871
620	29274
620	37294
620	88433
620	9400
620	31301
620	68218
620	33433
620	49008
620	87958
620	62341
620	46898
620	1416
620	30405
620	71071
620	40007
620	81427
620	94271
620	99025
620	33854
620	24897
621	63312
621	29932
621	38927
621	19193
621	23925
621	83560
621	19075
621	68060
621	7180
621	77224
621	20482
621	75926
621	43367
621	32222
621	11878
621	71875
621	85823
621	56868
621	85577
621	244
621	6076
621	25131
621	39460
621	38800
621	25593
621	17496
622	25989
622	22128
622	73455
622	81706
622	68161
622	11879
622	25741
622	48887
622	11346
622	42223
622	21865
622	38981
622	90867
622	29063
622	42575
622	32803
622	47815
622	9569
622	82056
622	49094
622	27079
622	82657
622	69793
622	64924
622	45680
622	57303
623	48903
623	89452
623	57029
623	14151
623	70867
623	59571
623	85878
623	68952
623	34132
623	11737
623	3484
623	1792
623	26367
623	74007
623	75522
623	77402
623	35320
623	48265
623	68131
623	25925
623	30252
623	95273
623	86410
623	94647
623	38940
623	80838
624	10014
624	65659
624	78440
624	89869
624	46785
624	58791
624	86878
624	95062
624	30486
624	62594
624	18885
624	19914
624	78932
624	47386
624	5174
624	90796
624	18564
624	70671
624	20051
624	68430
624	59138
624	74058
624	232
624	24667
624	94091
624	55597
625	46457
625	92343
625	87190
625	41198
625	74888
625	38105
625	92761
625	94779
625	57098
625	86951
625	63927
625	31718
625	10657
625	56503
625	50398
625	69082
625	34567
625	56664
625	37173
625	74707
625	92482
625	20564
625	24982
625	2030
625	7137
625	84269
\.


--
-- Data for Name: scorefinal; Type: TABLE DATA; Schema: public; Owner: wcuser
--

COPY public.scorefinal (match_id, pointequipea, pointequipeb, penaltie_equipea, penaltie_equipeb) FROM stdin;
1	4	1	\N	\N
2	3	0	\N	\N
3	2	1	\N	\N
4	3	1	\N	\N
5	1	0	\N	\N
6	3	0	\N	\N
7	4	0	\N	\N
8	3	0	\N	\N
9	1	0	\N	\N
10	1	0	\N	\N
11	6	3	\N	\N
12	4	0	\N	\N
13	1	0	\N	\N
14	4	0	\N	\N
15	3	1	\N	\N
16	6	1	\N	\N
17	6	1	\N	\N
18	4	2	\N	\N
19	3	2	\N	\N
20	2	1	\N	\N
21	5	2	\N	\N
22	4	2	\N	\N
23	7	1	\N	\N
24	3	1	\N	\N
25	3	2	\N	\N
26	3	2	\N	\N
27	2	1	\N	\N
28	3	2	\N	\N
29	2	1	\N	\N
30	1	1	\N	\N
31	1	0	\N	\N
32	3	1	\N	\N
33	1	0	\N	\N
34	3	2	\N	\N
35	2	1	\N	\N
36	1	1	\N	\N
37	3	3	\N	\N
38	3	1	\N	\N
39	6	0	\N	\N
40	2	1	\N	\N
41	6	5	\N	\N
42	3	0	\N	\N
43	2	1	\N	\N
44	4	2	\N	\N
45	1	1	\N	\N
46	2	0	\N	\N
47	3	1	\N	\N
48	8	0	\N	\N
49	2	1	\N	\N
50	5	1	\N	\N
51	2	1	\N	\N
52	4	2	\N	\N
53	4	2	\N	\N
54	4	0	\N	\N
55	3	0	\N	\N
56	2	0	\N	\N
57	3	1	\N	\N
58	3	2	\N	\N
59	2	2	\N	\N
60	4	1	\N	\N
61	2	0	\N	\N
62	1	0	\N	\N
63	2	2	\N	\N
64	2	0	\N	\N
65	5	2	\N	\N
66	1	0	\N	\N
67	2	0	\N	\N
68	8	0	\N	\N
69	2	1	\N	\N
70	7	1	\N	\N
71	2	2	\N	\N
72	6	1	\N	\N
73	3	2	\N	\N
74	3	1	\N	\N
75	2	1	\N	\N
76	5	0	\N	\N
77	1	0	\N	\N
78	1	0	\N	\N
79	2	0	\N	\N
80	2	1	\N	\N
81	9	0	\N	\N
82	4	1	\N	\N
83	4	4	\N	\N
84	7	0	\N	\N
85	1	1	\N	\N
86	5	0	\N	\N
87	3	2	\N	\N
88	8	3	\N	\N
89	7	0	\N	\N
90	4	1	\N	\N
91	2	0	\N	\N
92	7	2	\N	\N
93	4	1	\N	\N
94	7	5	\N	\N
95	4	2	\N	\N
96	4	2	\N	\N
97	2	0	\N	\N
98	4	2	\N	\N
99	6	1	\N	\N
100	3	1	\N	\N
101	3	2	\N	\N
102	3	0	\N	\N
103	1	3	\N	\N
104	1	0	\N	\N
105	7	3	\N	\N
106	1	1	\N	\N
107	1	1	\N	\N
108	3	0	\N	\N
109	2	2	\N	\N
110	3	1	\N	\N
111	2	2	\N	\N
112	3	2	\N	\N
113	3	2	\N	\N
114	1	1	\N	\N
115	0	0	\N	\N
116	2	0	\N	\N
117	2	1	\N	\N
118	0	0	\N	\N
119	6	1	\N	\N
120	2	2	\N	\N
121	2	1	\N	\N
122	3	3	\N	\N
123	4	0	\N	\N
124	2	0	\N	\N
125	2	2	\N	\N
126	2	1	\N	\N
127	2	1	\N	\N
128	1	0	\N	\N
129	1	0	\N	\N
130	4	0	\N	\N
131	2	0	\N	\N
132	1	0	\N	\N
133	5	2	\N	\N
134	3	1	\N	\N
135	6	3	\N	\N
136	5	2	\N	\N
137	2	1	\N	\N
138	3	1	\N	\N
139	2	0	\N	\N
140	1	0	\N	\N
141	2	0	\N	\N
142	0	0	\N	\N
143	1	0	\N	\N
144	2	1	\N	\N
145	3	1	\N	\N
146	2	0	\N	\N
147	0	0	\N	\N
148	3	1	\N	\N
149	4	4	\N	\N
150	2	1	\N	\N
151	1	0	\N	\N
152	6	1	\N	\N
153	2	1	\N	\N
154	2	0	\N	\N
155	2	1	\N	\N
156	0	0	\N	\N
157	5	0	\N	\N
158	3	0	\N	\N
159	3	1	\N	\N
160	0	0	\N	\N
161	3	1	\N	\N
162	2	1	\N	\N
163	1	0	\N	\N
164	1	0	\N	\N
165	4	2	\N	\N
166	3	1	\N	\N
167	1	0	\N	\N
168	3	1	\N	\N
169	0	0	\N	\N
170	5	0	\N	\N
171	2	0	\N	\N
172	3	0	\N	\N
173	1	1	\N	\N
174	2	1	\N	\N
175	3	1	\N	\N
176	2	0	\N	\N
177	2	1	\N	\N
178	2	1	\N	\N
179	3	1	\N	\N
180	1	1	\N	\N
181	0	0	\N	\N
182	3	0	\N	\N
183	1	0	\N	\N
184	2	0	\N	\N
185	0	0	\N	\N
186	2	0	\N	\N
187	3	1	\N	\N
188	1	0	\N	\N
189	2	0	\N	\N
190	2	1	\N	\N
191	3	1	\N	\N
192	2	1	\N	\N
193	1	0	\N	\N
194	5	3	\N	\N
195	2	1	\N	\N
196	4	0	\N	\N
197	2	1	\N	\N
198	2	1	\N	\N
199	2	1	\N	\N
200	4	2	\N	\N
201	0	0	\N	\N
202	2	0	\N	\N
203	1	0	\N	\N
204	3	2	\N	\N
205	3	0	\N	\N
206	1	0	\N	\N
207	4	1	\N	\N
208	2	1	\N	\N
209	4	1	\N	\N
210	0	0	\N	\N
211	2	1	\N	\N
212	3	0	\N	\N
213	4	0	\N	\N
214	1	1	\N	\N
215	1	0	\N	\N
216	5	2	\N	\N
217	2	0	\N	\N
218	1	0	\N	\N
219	3	2	\N	\N
220	3	1	\N	\N
221	1	0	\N	\N
222	0	0	\N	\N
223	1	0	\N	\N
224	1	1	\N	\N
225	4	2	\N	\N
226	4	1	\N	\N
227	0	1	\N	\N
228	3	2	\N	\N
229	3	1	\N	\N
230	4	3	\N	\N
231	1	0	\N	\N
232	4	1	\N	\N
233	0	0	\N	\N
234	1	0	\N	\N
235	2	0	\N	\N
236	0	2	\N	\N
237	0	0	\N	\N
238	0	2	\N	\N
239	3	1	\N	\N
240	3	2	\N	\N
241	0	3	\N	\N
242	1	1	\N	\N
243	0	0	\N	\N
244	9	0	\N	\N
245	1	1	\N	\N
246	0	0	\N	\N
247	1	1	\N	\N
248	0	7	\N	\N
249	0	0	\N	\N
250	1	1	\N	\N
251	0	3	\N	\N
252	1	0	\N	\N
253	1	4	\N	\N
254	3	0	\N	\N
255	4	1	\N	\N
256	2	1	\N	\N
257	0	2	\N	\N
258	1	0	\N	\N
259	4	0	\N	\N
260	0	1	\N	\N
261	1	2	\N	\N
262	0	2	\N	\N
263	2	1	\N	\N
264	4	2	\N	\N
265	0	1	\N	\N
266	1	1	\N	\N
267	2	0	\N	\N
268	2	1	\N	\N
269	0	1	\N	\N
270	1	2	\N	\N
271	0	0	\N	\N
272	2	1	\N	\N
273	3	1	\N	\N
274	2	1	\N	\N
275	2	1	\N	\N
276	1	1	\N	\N
277	3	0	\N	\N
278	3	1	\N	\N
279	3	1	\N	\N
280	1	0	\N	\N
281	6	0	\N	\N
282	2	1	\N	\N
283	1	0	\N	\N
284	0	0	\N	\N
285	0	0	\N	\N
286	1	1	\N	\N
287	3	1	\N	\N
288	3	1	\N	\N
289	0	0	\N	\N
290	0	1	\N	\N
291	1	0	\N	\N
292	1	0	\N	\N
293	4	1	\N	\N
294	3	2	\N	\N
295	1	5	\N	\N
296	0	0	\N	\N
297	3	0	\N	\N
298	2	0	\N	\N
299	0	1	\N	\N
300	1	0	\N	\N
301	2	2	\N	\N
302	0	0	\N	\N
303	3	2	\N	\N
304	1	2	\N	\N
305	3	1	\N	\N
306	6	0	\N	\N
307	2	1	\N	\N
308	3	1	\N	\N
309	0	1	\N	\N
310	0	0	\N	\N
311	2	1	\N	\N
312	0	0	\N	\N
313	10	1	\N	\N
314	5	2	\N	\N
315	1	2	\N	\N
316	3	1	\N	\N
317	1	1	\N	\N
318	0	1	\N	\N
319	1	1	\N	\N
320	0	0	\N	\N
321	1	1	\N	\N
322	4	1	\N	\N
323	4	1	\N	\N
324	0	0	\N	\N
325	1	0	\N	\N
326	3	0	\N	\N
327	4	1	\N	\N
328	2	0	\N	\N
329	2	1	\N	\N
330	0	2	\N	\N
331	4	1	\N	\N
332	1	1	\N	\N
333	5	1	\N	\N
334	1	1	\N	\N
335	2	2	\N	\N
336	1	1	\N	\N
337	2	0	\N	\N
338	4	0	\N	\N
339	3	2	\N	\N
340	1	1	\N	\N
341	0	1	\N	\N
342	1	0	\N	\N
343	1	0	\N	\N
344	0	1	\N	\N
345	0	1	\N	\N
346	3	0	\N	\N
347	2	1	\N	\N
348	0	0	\N	\N
349	2	2	\N	\N
350	0	1	\N	\N
351	1	3	\N	\N
352	2	1	\N	\N
353	4	1	\N	\N
354	0	0	\N	\N
355	3	2	\N	\N
356	0	0	\N	\N
357	0	2	\N	\N
358	3	3	5	4
359	3	2	\N	\N
360	3	1	\N	\N
361	1	1	\N	\N
362	0	1	\N	\N
363	0	1	\N	\N
364	3	1	\N	\N
365	6	0	\N	\N
366	0	0	\N	\N
367	1	2	\N	\N
368	1	1	\N	\N
369	1	0	\N	\N
370	1	0	\N	\N
371	1	1	\N	\N
372	0	1	\N	\N
373	1	1	\N	\N
374	1	1	\N	\N
375	1	1	\N	\N
376	2	0	\N	\N
377	1	0	\N	\N
378	0	0	\N	\N
379	1	1	\N	\N
380	1	2	\N	\N
381	1	0	\N	\N
382	1	2	\N	\N
383	2	1	\N	\N
384	6	1	\N	\N
385	0	3	\N	\N
386	2	0	\N	\N
387	2	0	\N	\N
388	2	3	\N	\N
389	0	1	\N	\N
390	2	2	\N	\N
391	3	0	\N	\N
392	1	3	\N	\N
393	0	3	\N	\N
394	0	3	\N	\N
395	2	0	\N	\N
396	0	0	\N	\N
397	2	0	\N	\N
398	3	4	\N	\N
399	4	0	\N	\N
400	1	0	\N	\N
401	0	2	\N	\N
402	0	1	\N	\N
403	3	0	\N	\N
404	1	5	\N	\N
405	1	1	3	4
406	0	0	4	1
407	2	1	\N	\N
408	1	1	4	5
409	0	2	\N	\N
410	2	0	\N	\N
411	2	4	\N	\N
412	3	2	\N	\N
413	0	1	\N	\N
414	0	2	\N	\N
415	0	2	\N	\N
416	1	0	\N	\N
417	1	5	\N	\N
418	2	1	\N	\N
419	4	1	\N	\N
420	1	0	\N	\N
421	1	1	\N	\N
422	2	0	\N	\N
423	1	1	\N	\N
424	0	0	\N	\N
425	2	0	\N	\N
426	2	1	\N	\N
427	1	0	\N	\N
428	1	0	\N	\N
429	0	1	\N	\N
430	5	1	\N	\N
431	1	0	\N	\N
432	1	2	\N	\N
433	0	0	\N	\N
434	0	0	\N	\N
435	3	1	\N	\N
436	1	3	\N	\N
437	1	1	\N	\N
438	0	4	\N	\N
439	1	1	\N	\N
440	4	1	\N	\N
441	2	1	\N	\N
442	2	0	\N	\N
443	1	0	\N	\N
444	1	2	\N	\N
445	1	2	\N	\N
446	0	1	\N	\N
447	1	0	\N	\N
448	1	1	\N	\N
449	2	1	\N	\N
450	4	1	\N	\N
451	0	1	\N	\N
452	2	1	\N	\N
453	0	0	5	4
454	2	0	\N	\N
455	1	2	\N	\N
456	1	0	\N	\N
457	0	0	3	2
458	0	1	\N	\N
459	0	1	\N	\N
460	2	3	\N	\N
461	1	1	4	3
462	1	1	4	3
463	2	1	\N	\N
464	1	0	\N	\N
465	4	0	\N	\N
466	4	0	\N	\N
467	3	0	\N	\N
468	0	1	\N	\N
469	2	3	\N	\N
470	0	5	\N	\N
471	4	0	\N	\N
472	1	0	\N	\N
473	2	2	\N	\N
474	0	5	\N	\N
475	0	8	\N	\N
476	0	3	\N	\N
477	0	2	\N	\N
478	0	3	\N	\N
479	4	1	\N	\N
480	2	1	\N	\N
481	2	0	\N	\N
482	0	2	\N	\N
483	1	2	\N	\N
484	0	1	\N	\N
485	3	2	\N	\N
486	7	0	\N	\N
487	1	4	\N	\N
488	2	5	\N	\N
489	4	0	\N	\N
490	1	2	\N	\N
491	1	0	\N	\N
492	2	2	\N	\N
493	1	1	\N	\N
494	0	1	\N	\N
495	1	3	\N	\N
496	1	0	\N	\N
497	1	0	\N	\N
498	2	2	\N	\N
499	2	0	\N	\N
500	2	1	\N	\N
501	4	0	\N	\N
502	1	1	\N	\N
503	3	0	\N	\N
504	1	4	\N	\N
505	2	1	\N	\N
506	1	0	\N	\N
507	0	0	\N	\N
508	2	1	\N	\N
509	3	0	\N	\N
510	3	1	\N	\N
511	1	0	\N	\N
512	2	1	\N	\N
513	2	1	\N	\N
514	4	0	\N	\N
515	0	2	\N	\N
516	0	1	\N	\N
517	1	3	\N	\N
518	3	2	\N	\N
519	1	1	\N	\N
520	0	0	\N	\N
521	6	1	\N	\N
522	1	1	\N	\N
523	0	1	\N	\N
524	1	2	\N	\N
525	0	2	\N	\N
526	0	2	\N	\N
527	3	2	\N	\N
528	3	0	\N	\N
529	1	3	\N	\N
530	3	2	\N	\N
531	2	0	\N	\N
532	1	0	\N	\N
533	1	2	\N	\N
534	1	1	1	3
535	2	1	\N	\N
536	2	3	\N	\N
537	2	1	\N	\N
538	2	2	4	5
539	1	2	\N	\N
540	0	1	\N	\N
541	4	0	\N	\N
542	0	0	3	2
543	1	0	\N	\N
544	0	1	\N	\N
545	3	2	\N	\N
546	8	0	\N	\N
547	5	0	\N	\N
548	3	3	\N	\N
549	1	2	\N	\N
550	3	2	\N	\N
551	3	3	\N	\N
552	2	0	\N	\N
553	4	2	\N	\N
554	2	0	\N	\N
555	1	6	\N	\N
556	2	0	\N	\N
557	2	3	\N	\N
558	7	0	\N	\N
559	3	1	\N	\N
560	4	1	\N	\N
561	0	4	\N	\N
562	3	1	\N	\N
563	3	0	\N	\N
564	1	1	3	4
565	0	1	\N	\N
566	1	0	\N	\N
567	0	2	\N	\N
568	0	2	\N	\N
569	2	1	\N	\N
570	2	2	\N	\N
571	2	2	\N	\N
572	1	1	\N	\N
573	0	0	\N	\N
574	0	1	\N	\N
575	3	0	\N	\N
576	2	3	\N	\N
577	1	3	\N	\N
578	0	0	\N	\N
579	1	0	\N	\N
580	1	0	\N	\N
581	1	3	\N	\N
582	2	0	\N	\N
583	1	0	\N	\N
584	2	0	\N	\N
585	1	1	\N	\N
586	3	0	\N	\N
587	1	1	\N	\N
588	3	0	\N	\N
589	1	1	\N	\N
590	4	0	\N	\N
591	1	0	\N	\N
592	0	0	\N	\N
593	0	1	\N	\N
594	2	2	\N	\N
595	5	0	\N	\N
596	2	2	\N	\N
597	5	0	\N	\N
598	1	2	\N	\N
599	1	0	\N	\N
600	2	1	\N	\N
601	1	1	\N	\N
602	2	1	\N	\N
603	1	2	\N	\N
604	0	3	\N	\N
605	2	1	\N	\N
606	2	2	\N	\N
607	1	3	\N	\N
608	6	1	\N	\N
609	1	1	\N	\N
610	2	2	\N	\N
611	2	0	\N	\N
612	0	1	\N	\N
613	1	0	\N	\N
614	1	2	\N	\N
615	0	2	\N	\N
616	1	1	\N	\N
617	1	0	\N	\N
618	4	1	\N	\N
619	1	0	\N	\N
620	1	4	\N	\N
621	2	1	\N	\N
622	2	1	\N	\N
623	0	1	\N	\N
624	2	2	4	3
625	0	0	3	4
626	3	2	\N	\N
627	2	1	\N	\N
628	0	3	\N	\N
629	1	1	4	2
630	2	1	\N	\N
631	1	2	\N	\N
632	0	3	\N	\N
633	3	0	\N	\N
634	2	1	\N	\N
635	7	1	\N	\N
636	1	1	\N	\N
637	1	1	\N	\N
638	2	1	\N	\N
639	1	2	\N	\N
640	1	1	\N	\N
641	0	5	\N	\N
642	7	1	\N	\N
643	1	3	\N	\N
644	7	0	\N	\N
645	2	0	\N	\N
646	3	1	\N	\N
647	7	1	\N	\N
648	6	0	\N	\N
649	1	4	\N	\N
650	3	1	\N	\N
651	0	2	\N	\N
652	4	0	\N	\N
653	3	3	\N	\N
654	2	0	\N	\N
655	0	2	\N	\N
656	3	0	\N	\N
657	2	0	\N	\N
658	3	1	\N	\N
659	3	2	\N	\N
660	4	3	\N	\N
661	2	0	\N	\N
662	0	5	\N	\N
663	0	0	5	4
664	0	0	5	4
665	0	1	\N	\N
666	1	1	\N	\N
667	1	2	\N	\N
668	8	0	\N	\N
669	1	0	\N	\N
670	2	2	\N	\N
671	1	1	\N	\N
672	3	1	\N	\N
673	0	1	\N	\N
674	2	1	\N	\N
675	2	0	\N	\N
676	0	2	\N	\N
677	2	2	\N	\N
678	2	0	\N	\N
679	2	0	\N	\N
680	3	2	\N	\N
681	1	1	\N	\N
682	1	1	\N	\N
683	1	0	\N	\N
684	0	0	\N	\N
685	2	1	\N	\N
686	3	1	\N	\N
687	0	1	\N	\N
688	1	0	\N	\N
689	1	2	\N	\N
690	4	0	\N	\N
691	2	1	\N	\N
692	1	1	\N	\N
693	1	0	\N	\N
694	1	1	\N	\N
695	1	1	\N	\N
696	4	0	\N	\N
697	2	0	\N	\N
698	3	3	\N	\N
699	0	2	\N	\N
700	0	3	\N	\N
701	0	0	\N	\N
702	1	1	\N	\N
703	1	3	\N	\N
704	2	3	\N	\N
705	2	5	\N	\N
706	3	0	\N	\N
707	1	0	\N	\N
708	1	1	\N	\N
709	3	2	\N	\N
710	0	2	\N	\N
711	3	1	\N	\N
712	0	1	\N	\N
713	1	0	\N	\N
714	0	3	\N	\N
715	1	2	\N	\N
716	1	1	3	2
717	0	2	\N	\N
718	2	0	\N	\N
719	0	1	\N	\N
720	2	1	\N	\N
721	1	2	\N	\N
722	1	0	\N	\N
723	0	0	3	5
724	0	1	\N	\N
725	1	0	\N	\N
726	1	0	\N	\N
727	2	3	\N	\N
728	0	2	\N	\N
729	2	0	\N	\N
730	0	3	\N	\N
731	4	1	\N	\N
732	6	0	\N	\N
733	3	1	\N	\N
734	3	0	\N	\N
735	1	2	\N	\N
736	1	0	\N	\N
737	1	4	\N	\N
738	3	0	\N	\N
739	1	0	\N	\N
740	3	0	\N	\N
741	0	3	\N	\N
742	1	0	\N	\N
743	1	1	\N	\N
744	5	0	\N	\N
745	1	1	\N	\N
746	1	7	\N	\N
747	1	6	\N	\N
748	3	1	\N	\N
749	3	0	\N	\N
750	0	3	\N	\N
751	2	1	\N	\N
752	1	0	\N	\N
753	1	2	\N	\N
754	1	0	\N	\N
755	7	1	\N	\N
756	0	1	\N	\N
757	0	3	\N	\N
758	2	1	\N	\N
759	3	1	\N	\N
760	2	1	\N	\N
761	4	2	\N	\N
762	0	2	\N	\N
763	1	0	\N	\N
764	0	0	\N	\N
765	2	1	\N	\N
766	0	1	\N	\N
767	3	1	\N	\N
768	0	1	\N	\N
769	3	1	\N	\N
770	0	3	\N	\N
771	2	0	\N	\N
772	2	1	\N	\N
773	0	0	\N	\N
774	1	0	\N	\N
775	4	0	\N	\N
776	2	2	\N	\N
777	1	0	\N	\N
778	3	0	\N	\N
779	2	0	\N	\N
780	1	0	\N	\N
781	6	0	\N	\N
782	2	1	\N	\N
783	0	0	\N	\N
784	2	0	\N	\N
785	0	2	\N	\N
786	1	1	\N	\N
787	0	0	\N	\N
788	2	0	\N	\N
789	1	1	\N	\N
790	0	2	\N	\N
791	0	4	\N	\N
792	3	1	\N	\N
793	1	2	\N	\N
794	0	3	\N	\N
795	2	0	\N	\N
796	2	2	\N	\N
797	1	1	\N	\N
798	2	1	\N	\N
799	3	2	\N	\N
800	0	0	\N	\N
801	0	2	\N	\N
802	2	1	\N	\N
803	2	2	\N	\N
804	1	4	\N	\N
805	0	1	\N	\N
806	1	0	\N	\N
807	2	0	\N	\N
808	0	2	\N	\N
809	2	0	\N	\N
810	2	1	\N	\N
811	1	0	\N	\N
812	1	0	\N	\N
813	1	0	\N	\N
814	0	0	0	3
815	3	0	\N	\N
816	1	3	\N	\N
817	1	1	4	2
818	3	0	\N	\N
819	0	0	1	3
820	0	1	\N	\N
821	0	2	\N	\N
822	0	1	\N	\N
823	3	1	\N	\N
824	1	1	5	3
825	11	0	\N	\N
826	2	2	\N	\N
827	2	2	\N	\N
828	1	1	\N	\N
829	1	4	\N	\N
830	0	5	\N	\N
831	2	1	\N	\N
832	3	2	\N	\N
833	0	1	\N	\N
834	0	2	\N	\N
835	0	0	\N	\N
836	2	0	\N	\N
837	4	0	\N	\N
838	2	0	\N	\N
839	1	1	\N	\N
840	4	0	\N	\N
841	6	1	\N	\N
842	2	0	\N	\N
843	0	1	\N	\N
844	1	2	\N	\N
845	2	2	\N	\N
846	7	2	\N	\N
847	1	0	\N	\N
848	2	0	\N	\N
849	3	0	\N	\N
850	3	0	\N	\N
851	1	0	\N	\N
852	3	2	\N	\N
853	3	0	\N	\N
854	0	4	\N	\N
855	1	4	\N	\N
856	2	0	\N	\N
857	1	1	\N	\N
858	0	0	\N	\N
859	2	0	\N	\N
860	1	0	\N	\N
861	1	1	\N	\N
862	0	1	\N	\N
863	0	1	\N	\N
864	4	0	\N	\N
865	2	0	\N	\N
866	1	0	\N	\N
867	1	1	\N	\N
868	1	1	\N	\N
869	0	0	\N	\N
870	2	1	\N	\N
871	0	1	\N	\N
872	0	1	\N	\N
873	0	3	\N	\N
874	4	1	\N	\N
875	2	1	\N	\N
876	0	2	\N	\N
877	0	1	\N	\N
878	2	2	\N	\N
879	0	0	\N	\N
880	1	0	\N	\N
881	1	1	\N	\N
882	1	2	\N	\N
883	0	2	\N	\N
884	1	1	\N	\N
885	3	1	\N	\N
886	7	0	\N	\N
887	1	0	\N	\N
888	2	0	\N	\N
889	1	2	\N	\N
890	0	1	\N	\N
891	0	2	\N	\N
892	2	2	\N	\N
893	0	1	\N	\N
894	1	0	\N	\N
895	2	1	\N	\N
896	0	1	\N	\N
897	0	0	\N	\N
898	3	2	\N	\N
899	1	2	\N	\N
900	1	3	\N	\N
901	0	3	\N	\N
902	0	0	\N	\N
903	1	2	\N	\N
904	0	0	\N	\N
905	2	1	\N	\N
906	1	2	\N	\N
907	4	1	\N	\N
908	3	1	\N	\N
909	2	1	\N	\N
910	3	0	\N	\N
911	0	0	5	3
912	1	0	\N	\N
913	2	1	\N	\N
914	1	1	4	2
915	0	4	\N	\N
916	0	1	\N	\N
917	2	3	\N	\N
918	0	1	\N	\N
919	2	3	\N	\N
920	0	1	\N	\N
921	0	1	\N	\N
922	2	1	\N	\N
923	2	1	\N	\N
924	1	1	\N	\N
925	0	1	\N	\N
926	2	0	\N	\N
927	1	0	\N	\N
928	1	0	\N	\N
929	0	4	\N	\N
930	1	0	\N	\N
931	4	0	\N	\N
932	1	2	\N	\N
933	0	1	\N	\N
934	3	0	\N	\N
935	3	2	\N	\N
936	3	0	\N	\N
937	2	0	\N	\N
938	2	2	\N	\N
939	0	1	\N	\N
940	2	4	\N	\N
941	2	1	\N	\N
942	0	3	\N	\N
943	0	0	\N	\N
944	2	1	\N	\N
945	1	1	3	4
946	0	1	\N	\N
947	3	1	\N	\N
948	2	2	3	5
949	1	3	\N	\N
950	3	1	\N	\N
951	2	1	\N	\N
952	2	2	3	1
953	3	1	\N	\N
954	1	0	\N	\N
955	1	5	\N	\N
956	3	1	\N	\N
957	3	0	\N	\N
958	1	3	\N	\N
959	1	2	\N	\N
960	2	1	\N	\N
961	2	1	\N	\N
962	3	0	\N	\N
963	2	1	\N	\N
964	4	0	\N	\N
965	0	0	\N	\N
966	1	2	\N	\N
967	2	1	\N	\N
968	0	0	\N	\N
969	1	1	\N	\N
970	2	3	\N	\N
971	0	2	\N	\N
972	0	4	\N	\N
973	2	1	\N	\N
974	2	1	\N	\N
975	0	0	\N	\N
976	0	1	\N	\N
977	2	5	\N	\N
978	1	2	\N	\N
979	1	0	\N	\N
980	2	2	\N	\N
981	1	0	\N	\N
982	1	0	\N	\N
983	2	4	\N	\N
984	2	2	\N	\N
985	0	3	\N	\N
986	2	0	\N	\N
987	1	4	\N	\N
988	1	3	\N	\N
989	0	0	\N	\N
990	0	1	\N	\N
991	1	4	\N	\N
992	2	1	\N	\N
993	3	1	\N	\N
994	2	3	\N	\N
995	0	3	\N	\N
996	0	0	\N	\N
997	2	1	\N	\N
998	0	1	\N	\N
999	1	1	\N	\N
1000	0	1	\N	\N
1001	1	1	3	2
1002	2	0	\N	\N
1003	2	1	\N	\N
1004	1	1	5	3
1005	2	0	\N	\N
1006	2	1	\N	\N
1007	1	0	\N	\N
1008	2	1	\N	\N
1009	0	1	\N	\N
1010	2	1	\N	\N
1011	1	0	\N	\N
1012	0	0	4	3
1013	1	7	\N	\N
1014	0	0	2	4
1015	0	3	\N	\N
1016	1	0	\N	\N
1017	1	0	\N	\N
1018	0	1	\N	\N
1019	4	0	\N	\N
1020	10	0	\N	\N
1021	3	3	\N	\N
1022	6	0	\N	\N
1023	3	1	\N	\N
1024	1	0	\N	\N
1025	1	0	\N	\N
1026	1	1	\N	\N
1027	1	1	\N	\N
1028	2	0	\N	\N
1029	1	0	\N	\N
1030	1	1	\N	\N
1031	0	0	\N	\N
1032	2	3	\N	\N
1033	10	1	\N	\N
1034	2	0	\N	\N
1035	2	1	\N	\N
1036	0	0	\N	\N
1037	0	2	\N	\N
1038	1	0	\N	\N
1039	2	1	\N	\N
1040	2	2	\N	\N
1041	0	4	\N	\N
1042	1	3	\N	\N
1043	2	2	\N	\N
1044	1	1	\N	\N
1045	1	2	\N	\N
1046	0	1	\N	\N
1047	0	1	\N	\N
1048	1	1	\N	\N
1049	2	1	\N	\N
1050	0	5	\N	\N
1051	2	1	\N	\N
1052	0	1	\N	\N
1053	4	1	\N	\N
1054	1	0	\N	\N
1055	0	1	\N	\N
1056	3	0	\N	\N
1057	1	0	\N	\N
1058	1	2	\N	\N
1059	2	0	\N	\N
1060	2	1	\N	\N
1061	1	1	5	4
1062	0	1	\N	\N
1063	0	1	\N	\N
1064	2	1	\N	\N
1065	2	0	\N	\N
1066	2	1	\N	\N
1067	0	1	\N	\N
1068	5	2	\N	\N
1069	5	0	\N	\N
1070	0	1	\N	\N
1071	0	1	\N	\N
1072	3	3	\N	\N
1073	2	1	\N	\N
1074	1	1	\N	\N
1075	0	1	\N	\N
1076	2	0	\N	\N
1077	0	1	\N	\N
1078	0	1	\N	\N
1079	1	1	\N	\N
1080	1	0	\N	\N
1081	3	0	\N	\N
1082	1	2	\N	\N
1083	1	2	\N	\N
1084	1	2	\N	\N
1085	3	1	\N	\N
1086	1	0	\N	\N
1087	1	0	\N	\N
1088	0	1	\N	\N
1089	1	1	\N	\N
1090	1	0	\N	\N
1091	0	3	\N	\N
1092	2	0	\N	\N
1093	2	0	\N	\N
1094	1	2	\N	\N
1095	5	2	\N	\N
1096	1	2	\N	\N
1097	2	1	\N	\N
1098	6	1	\N	\N
1099	2	2	\N	\N
1100	0	3	\N	\N
1101	2	1	\N	\N
1102	3	0	\N	\N
1103	2	2	\N	\N
1104	1	1	\N	\N
1105	0	2	\N	\N
1106	0	0	\N	\N
1107	1	2	\N	\N
1108	1	2	\N	\N
1109	2	0	\N	\N
1110	0	3	\N	\N
1111	0	2	\N	\N
1112	2	2	\N	\N
1113	0	1	\N	\N
1114	0	1	\N	\N
1115	0	1	\N	\N
1116	1	2	\N	\N
1117	4	3	\N	\N
1118	2	1	\N	\N
1119	1	1	3	4
1120	1	1	3	2
1121	2	0	\N	\N
1122	3	2	\N	\N
1123	1	0	\N	\N
1124	1	1	3	4
1125	0	2	\N	\N
1126	1	2	\N	\N
1127	0	2	\N	\N
1128	2	2	3	4
1129	1	0	\N	\N
1130	2	1	\N	\N
1131	2	0	\N	\N
1132	4	2	\N	\N
1133	4	0	\N	\N
1134	1	0	\N	\N
1135	3	1	\N	\N
1136	3	0	\N	\N
1137	1	2	\N	\N
1138	3	0	\N	\N
1139	2	1	\N	\N
1140	0	0	\N	\N
1141	1	0	\N	\N
1142	0	1	\N	\N
1143	0	2	\N	\N
1144	13	0	\N	\N
1145	2	0	\N	\N
1146	1	0	\N	\N
1147	2	1	\N	\N
1148	3	2	\N	\N
1149	0	1	\N	\N
1150	2	1	\N	\N
1151	0	5	\N	\N
1152	1	0	\N	\N
1153	3	1	\N	\N
1154	2	0	\N	\N
1155	5	1	\N	\N
1156	3	0	\N	\N
1157	0	0	\N	\N
1158	0	4	\N	\N
1159	0	1	\N	\N
1160	1	2	\N	\N
1161	0	1	\N	\N
1162	1	4	\N	\N
1163	0	2	\N	\N
1164	3	3	\N	\N
1165	2	1	\N	\N
1166	2	1	\N	\N
1167	0	2	\N	\N
1168	0	2	\N	\N
1169	3	0	\N	\N
1170	1	1	4	1
1171	3	0	\N	\N
1172	2	1	\N	\N
1173	1	2	\N	\N
1174	1	0	\N	\N
1175	2	0	\N	\N
1176	2	1	\N	\N
1177	0	3	\N	\N
1178	1	2	\N	\N
1179	0	2	\N	\N
1180	1	2	\N	\N
1181	1	2	\N	\N
1182	1	0	\N	\N
1183	1	2	\N	\N
1184	2	0	\N	\N
1185	0	2	\N	\N
1186	6	2	\N	\N
1187	0	2	\N	\N
1188	1	1	\N	\N
1189	1	2	\N	\N
1190	0	0	\N	\N
1191	0	0	\N	\N
1192	4	1	\N	\N
1193	0	0	\N	\N
1194	1	2	\N	\N
1195	7	0	\N	\N
1196	1	0	\N	\N
1197	1	0	\N	\N
1198	0	0	\N	\N
1199	3	2	\N	\N
1200	2	0	\N	\N
1201	0	2	\N	\N
1202	1	3	\N	\N
1203	1	1	\N	\N
1204	0	0	\N	\N
1205	0	1	\N	\N
1206	2	0	\N	\N
1207	2	1	\N	\N
1208	2	0	\N	\N
1209	0	1	\N	\N
1210	0	2	\N	\N
1211	4	1	\N	\N
1212	1	1	\N	\N
1213	3	3	\N	\N
1214	2	3	\N	\N
1215	1	0	\N	\N
1216	2	0	\N	\N
1217	1	2	\N	\N
1218	2	0	\N	\N
1219	0	1	\N	\N
1220	0	3	\N	\N
1221	1	0	\N	\N
1222	1	0	\N	\N
1223	0	2	\N	\N
1224	1	2	\N	\N
1225	1	2	\N	\N
1226	0	0	\N	\N
1227	2	4	\N	\N
1228	2	1	\N	\N
1229	0	2	\N	\N
1230	2	1	\N	\N
1231	1	0	\N	\N
1232	2	3	\N	\N
1233	3	1	\N	\N
1234	2	1	\N	\N
1235	3	1	\N	\N
1236	3	0	\N	\N
1237	1	1	1	3
1238	4	1	\N	\N
1239	0	0	3	0
1240	6	1	\N	\N
1241	1	1	4	2
1242	2	2	3	4
1243	1	0	\N	\N
1244	1	2	\N	\N
1245	3	0	\N	\N
1246	2	0	\N	\N
1247	2	1	\N	\N
1248	3	3	4	2
\.


--
-- Data for Name: selectionneur; Type: TABLE DATA; Schema: public; Owner: wcuser
--

COPY public.selectionneur (id_staff, prenomstaff, nomstaff, id_equipe) FROM stdin;
1	Francisco	Bru	9
2	Raoul	Caudron	6
3	Píndaro	de Carvalho Rodrigues	4
4	José	Durand Laguna	8
5	Hector	Goetinck	2
6	Juan	Luque de Serrallonga	7
7	Robert	Millar	11
8	Francisco	Olazar	1
9	György	Orth	5
10	Costel	Rădulescu	10
11	Ulises	Saucedo	3
12	Boško	Simonović	13
13	Alberto	Suppici	12
14	Juan José	Tramutola	1
15	Amadeo	García	26
16	Bob	Glendenning	24
17	Hector	Goetinck	16
18	David	Gould	29
19	George	Kimpton	20
20	James	McCrae	19
21	Hugo	Meisl	15
22	Heinrich	Müller	28
23	Ödön	Nádas	22
24	Otto	Nerz	21
25	Felipe	Pascucci	14
26	Karel	Petrů	18
27	John	Pettersson	27
28	Vittorio	Pozzo	23
29	Costel	Rădulescu	25
30	Josef	Uridil	25
31	Luiz	Vinhaes	17
32	Gaston	Barreau	35
33	Jack	Butler	30
34	Károly	Dietz	37
35	Bob	Glendenning	39
36	Asbjørn	Halvorsen	40
37	Sepp	Herberger	36
38	Józef	Kałuża	41
39	Johan	Mastenbroek	34
40	Josef	Meissner	33
41	József	Nagy	43
42	Adhemar	Pimenta	31
43	Vittorio	Pozzo	38
44	Costel	Rădulescu	42
45	Karl	Rappan	44
46	Alexandru	Săvulescu	42
47	Alfréd	Schaffer	37
48	José	Tapia	32
49	Franco	Andreoli	54
50	Milorad	Arsenijević	57
51	Alberto	Buccicardi	47
52	Flávio	Costa	46
53	Guillermo	Eizaguirre	52
54	Manuel	Fleitas Solich	51
55	William	Jeffrey	55
56	Juan	López	56
57	Ferruccio	Novo	49
58	Mario	Pretto	45
59	George	Raynor	53
60	Octavio	Vial	50
61	Walter	Winterbottom	48
62	Andy	Beattie	67
63	Karol	Borhy	61
64	Lajos	Czeizler	65
65	Sepp	Herberger	72
66	Yong-sik	Kim	68
67	Doug	Livingstone	59
68	Juan	López	71
69	Antonio	López Herranz	66
70	Zezé	Moreira	60
71	Walter	Nausch	58
72	Pierre	Pibarot	63
73	Sandro	Puppo	70
74	Karl	Rappan	69
75	Gusztáv	Sebes	64
76	Aleksandar	Tirnanić	73
77	Walter	Winterbottom	62
78	Karl	Argauer	75
79	Lajos	Baróti	80
80	Albert	Batteux	79
81	Matt	Busby	84
82	Peter	Doherty	82
83	Vicente	Feola	76
84	Aurelio	González	83
85	Sepp	Herberger	88
86	Gavriil	Kachalin	85
87	Karel	Kolský	77
88	Antonio	López Herranz	81
89	Jimmy	Murphy	87
90	George	Raynor	86
91	Guillermo	Stábile	74
92	Aleksandar	Tirnanić	89
93	Dawson	Walker	84
94	Walter	Winterbottom	78
95	Lajos	Baróti	97
96	Juan Carlos	Corazzo	103
97	Giovanni	Ferrari	98
98	Sepp	Herberger	104
99	Helenio	Herrera	101
100	Gavriil	Kachalin	100
101	Juan Carlos	Lorenzo	90
102	Ljubomir	Lovrić	105
103	Paolo	Mazza	98
104	Prvoslav	Mihajlović	105
105	Aymoré	Moreira	91
106	Georgi	Pachedzhiev	92
107	Adolfo	Pedernera	94
108	Karl	Rappan	102
109	Fernando	Riera	93
110	Ignacio	Tréllez	99
111	Rudolf	Vytlačil	95
112	Walter	Winterbottom	96
113	Luis	Álamos	109
114	Lajos	Baróti	112
115	Edmondo	Fabbri	113
116	Vicente	Feola	107
117	Alfredo	Foni	119
118	Otto	Glória	116
119	Henri	Guérin	111
120	Juan Carlos	Lorenzo	106
121	Nikolai	Morozov	117
122	Rye-hyun	Myung	115
123	Alf	Ramsey	110
124	Helmut	Schön	121
125	Ignacio	Tréllez	114
126	Ondino	Viera	120
127	José	Villalonga	118
128	Rudolf	Vytlačil	108
129	Orvar	Bergmark	135
130	Stefan	Bozhkov	124
131	Raúl	Cárdenas	130
132	Hernán	Carrasco	126
133	not applicable	Didi	132
134	Raymond	Goethals	122
135	Juan	Hohberg	136
136	Gavriil	Kachalin	134
137	Jozef	Marko	125
138	Angelo	Niculescu	133
139	Alf	Ramsey	127
140	Emmanuel	Scheffer	128
141	Helmut	Schön	137
142	Ferruccio	Valcareggi	129
143	Blagoje	Vidinić	131
144	Mário	Zagallo	123
145	Luis	Álamos	142
146	Georg	Buschner	143
147	Vladislao	Cap	138
148	Georg	Ericson	149
149	Kazimierz	Górski	147
150	Rinus	Michels	146
151	Miljan	Miljanić	152
152	Hristo	Mladenov	141
153	Willie	Ormond	148
154	Roberto	Porta	150
155	Rale	Rasic	139
156	Helmut	Schön	151
157	Antoine	Tassy	144
158	Ferruccio	Valcareggi	145
159	Blagoje	Vidinić	153
160	Mário	Zagallo	140
161	Lajos	Baróti	158
162	Enzo	Bearzot	160
163	Marcos	Calderón	163
164	Abdelmajid	Chetali	168
165	Cláudio	Coutinho	156
166	Georg	Ericson	167
167	Jacek	Gmoch	164
168	Ernst	Happel	162
169	Michel	Hidalgo	157
170	Ladislao	Kubala	166
171	Ally	MacLeod	165
172	César Luis	Menotti	154
173	Heshmat	Mohajerani	159
174	José Antonio	Roca	161
175	Helmut	Schön	169
176	Helmut	Senekowitsch	155
177	John	Adshead	185
178	Enzo	Bearzot	183
179	Konstantin	Beskov	190
180	Billy	Bingham	186
181	José	de la Paz Herrera	181
182	Jupp	Derwall	192
183	Ron	Greenwood	179
184	Michel	Hidalgo	180
185	Mahieddine	Khalef	170
186	Felix	Latzke	172
187	Rachid	Mekhloufi	170
188	César Luis	Menotti	171
189	Kálmán	Mészöly	182
190	Miljan	Miljanić	193
191	Carlos Alberto	Parreira	184
192	Antoni	Piechniczek	188
193	Mauricio	Rodríguez	178
194	José	Santamaría	191
195	Telê	Santana	174
196	Luis	Santibáñez	176
197	Georg	Schmidt	172
198	Jock	Stein	189
199	Guy	Thys	173
200	not applicable	Tim	187
201	Jozef	Vengloš	177
202	Jean	Vincent	175
203	Enzo	Bearzot	205
204	Franz	Beckenbauer	217
205	Carlos	Bilardo	195
206	Billy	Bingham	208
207	Omar	Borrás	216
208	Evaristo	de Macedo	204
209	José	Faria	207
210	Alex	Ferguson	212
211	Jung-nam	Kim	213
212	Valeri	Lobanovsky	214
213	György	Mezey	203
214	Henri	Michel	202
215	Bora	Milutinović	206
216	Miguel	Muñoz	215
217	Antoni	Piechniczek	210
218	Sepp	Piontek	200
219	Cayetano	Ré	209
220	Bobby	Robson	201
221	Rabah	Saâdane	194
222	Telê	Santana	197
223	Guy	Thys	196
224	José	Torres	211
225	Ivan	Vutsov	198
226	Tony	Waiters	199
227	Mahmoud	Al-Gohari	226
228	Franz	Beckenbauer	240
229	Leo	Beenhakker	229
230	Carlos	Bilardo	218
231	Jack	Charlton	230
232	Bob	Gansler	238
233	Josef	Hickersberger	219
234	Emerich	Jenei	231
235	Sebastião	Lazaroni	221
236	Hoe-taik	Lee	233
237	Valeriy	Lobanovskyi	234
238	Francisco	Maturana	223
239	Bora	Milutinović	224
240	Valery	Nepomnyashchy	222
241	Olle	Nordin	236
242	Ivica	Osim	241
243	Carlos Alberto	Parreira	237
244	Bobby	Robson	227
245	Andy	Roxburgh	232
246	Luis	Suárez	235
247	Óscar	Tabárez	239
248	Guy	Thys	220
249	Jozef	Vengloš	225
250	Azeglio	Vicini	228
251	Gero	Bisanz	246
252	Dave	Boardman	249
253	Jo	Bonfrère	250
254	Tsu-pin	Chong	244
255	Anson	Dorrance	253
256	Keld	Gantzhorn	245
257	Sergio	Guenza	247
258	Gunilla	Paijkull	252
259	Even	Pellerud	251
260	Fernando	Pires	242
261	Ruihua	Shang	243
262	Tamotsu	Suzuki	248
263	Dick	Advocaat	266
264	Xabier	Azkargorta	256
265	Alfio	Basile	254
266	Abdellah	Blinda	265
267	Jack	Charlton	269
268	Javier	Clemente	274
269	Roy	Hodgson	276
270	Anghel	Iordănescu	270
271	Ho	Kim	273
272	Francisco	Maturana	260
273	Miguel	Mejía Barón	264
274	Henri	Michel	259
275	Bora	Milutinović	277
276	Egil	Olsen	268
277	Alketas	Panagoulias	262
278	Carlos Alberto	Parreira	257
279	Dimitar	Penev	258
280	Arrigo	Sacchi	263
281	Pavel	Sadyrin	271
282	Jorge	Solari	272
283	Tommy	Svensson	275
284	Paul	Van Himst	255
285	Berti	Vogts	261
286	Clemens	Westerhof	267
287	Sylvie	Béliveau	280
288	Gero	Bisanz	284
289	Ted	Copeland	283
290	Tony	DiCicco	289
291	Ademar	Fonseca	279
292	Keld	Gantzhorn	282
293	Paul	Hamilton	286
294	Yuanan	Ma	281
295	Even	Pellerud	287
296	Tom	Sermanni	278
297	Bengt	Simonsson	288
298	Tamotsu	Suzuki	285
299	Nelson	Acosta	296
300	Mohammed	Al-Kharashy	314
301	Miroslav	Blažević	298
302	Hristo	Bonev	294
303	Craig	Brown	315
304	Paulo César	Carpegiani	312
305	Bum-kun	Cha	317
306	Javier	Clemente	318
307	Hernán Darío	Gómez	297
308	Guus	Hiddink	309
309	Glenn	Hoddle	300
310	Anghel	Iordănescu	313
311	Aimé	Jacquet	301
312	Bo	Johansson	299
313	Henryk	Kasperczak	319
314	Manuel	Lapuente	307
315	Claude	Le Roy	295
316	Georges	Leekens	292
317	Cesare	Maldini	304
318	Henri	Michel	308
319	Bora	Milutinović	310
320	Takeshi	Okada	306
321	Egil	Olsen	311
322	Carlos Alberto	Parreira	314
323	Daniel	Passarella	290
324	Herbert	Prohaska	291
325	Steve	Sampson	320
326	Slobodan	Santrač	321
327	Ali	Selmi	319
328	Renê	Simões	305
329	Jalal	Talebi	303
330	Philippe	Troussier	316
331	Berti	Vogts	302
332	Mário	Zagallo	293
333	Emmanual Kwasi	Afranie	328
334	Greg	Brown	322
335	Yuri	Bystritsky	335
336	Leonardo	Cuéllar	331
337	Tony	DiCicco	337
338	Marika	Domanski-Lyfors	336
339	Carlo	Facchin	329
340	Per-Mathias	Høgmo	334
341	Jørgen	Hvidemose	326
342	Mabo	Ismaila	332
343	Yuanan	Ma	325
344	Satoshi	Miyauchi	330
345	Dong-chan	Myong	333
346	Tina	Theune-Meyer	327
347	Neil	Turnbull	324
348	not applicable	Wilsinho	323
349	Javier	Aguirre	352
350	Nasser	Al-Johar	359
351	Bruce	Arena	368
352	Marcelo	Bielsa	338
353	José Antonio	Camacho	364
354	Jerzy	Engel	355
355	Sven-Göran	Eriksson	347
356	Hernán Darío	Gómez	346
357	Alexandre	Guimarães	343
358	Şenol	Güneş	367
359	Guus	Hiddink	363
360	Mirko	Jozić	344
361	Srečko	Katanec	361
362	Lars	Lagerbäck	365
363	Roger	Lemerre	348
364	Cesare	Maldini	354
365	Mick	McCarthy	357
366	Bruno	Metsu	360
367	Bora	Milutinović	342
368	António	Oliveira	356
369	Morten	Olsen	345
370	Festus	Onigbinde	353
371	Víctor	Púa	369
372	Oleg	Romantsev	358
373	Winfried	Schäfer	341
374	Luiz Felipe	Scolari	340
375	Tommy	Söderberg	365
376	Jomo	Sono	362
377	Ammar	Souayah	366
378	Giovanni	Trapattoni	350
379	Philippe	Troussier	351
380	Rudi	Völler	349
381	Robert	Waseige	339
382	Jong-goan	An	383
383	Oko	Aryee	377
384	Carlos	Borrello	370
385	Yuri	Bystritsky	382
386	Marika	Domanski-Lyfors	384
387	Paulo	Gonçalves	372
388	April	Heinrichs	385
389	Élisabeth	Loisel	375
390	Liangxing	Ma	374
391	Samuel	Okpodu	379
392	Even	Pellerud	373
393	Song-gun	Ri	380
394	Adrian	Santrac	371
395	Åge	Steen	381
396	Tina	Theune-Meyer	376
397	Eiji	Ueda	378
398	Dick	Advocaat	409
399	Luis	Aragonés	410
400	Bruce	Arena	417
401	Leo	Beenhakker	414
402	Oleg	Blokhin	416
403	Karel	Brückner	392
404	Raymond	Domenech	395
405	Ratomir	Dujković	397
406	Sven-Göran	Eriksson	394
407	Oliveira	Gonçalves	386
408	Alexandre	Guimarães	390
409	Guus	Hiddink	388
410	Branko	Ivanković	398
411	Paweł	Janas	405
412	Jürgen	Klinsmann	396
413	Zlatko	Kranjčar	391
414	Köbi	Kuhn	412
415	Ricardo	La Volpe	402
416	Lars	Lagerbäck	411
417	Roger	Lemerre	415
418	Marcello	Lippi	399
419	Henri	Michel	400
420	Marcos	Paquetá	407
421	Carlos Alberto	Parreira	389
422	José	Pékerman	387
423	Ilija	Petković	408
424	Otto	Pfister	413
425	Aníbal	Ruiz	404
426	Luiz Felipe	Scolari	406
427	Luis Fernando	Suárez	393
428	Marco	van Basten	403
429	not applicable	Zico	401
430	Jorge	Barcellos	420
431	Bjarne	Berntsen	431
432	Carlos	Borrello	418
433	Thomas	Dennerby	432
434	Marika	Domanski-Lyfors	422
435	Ntiero	Effiom	429
436	Kenneth	Heiner-Møller	423
437	John	Herdman	428
438	Kwang-min	Kim	430
439	Silvia	Neid	425
440	Hiroshi	Ohashi	427
441	Isaac	Paha	426
442	Even	Pellerud	421
443	Hope	Powell	424
444	Greg	Ryan	433
445	Tom	Sermanni	419
446	Javier	Aguirre	450
447	Radomir	Antić	457
448	Marcelo	Bielsa	439
449	Bob	Bradley	464
450	Fabio	Capello	441
451	Vicente	del Bosque	462
452	Raymond	Domenech	442
453	not applicable	Dunga	437
454	Sven-Göran	Eriksson	448
455	Ricki	Herbert	452
456	Ottmar	Hitzfeld	463
457	Jung-moo	Huh	461
458	Matjaž	Kek	459
459	Jong-hun	Kim	454
460	Lars	Lagerbäck	453
461	Paul	Le Guen	438
462	Marcello	Lippi	447
463	Joachim	Löw	443
464	Diego	Maradona	435
465	Gerardo	Martino	455
466	Takeshi	Okada	449
467	Morten	Olsen	440
468	Carlos Alberto	Parreira	460
469	Carlos	Queiroz	456
470	Milovan	Rajevac	444
471	Otto	Rehhagel	445
472	Reinaldo	Rueda	446
473	Rabah	Saâdane	434
474	Óscar	Tabárez	465
475	Bert	van Marwijk	451
476	Pim	Verbeek	436
477	Vladimír	Weiss	458
478	Bruno	Bini	472
479	Leonardo	Cuéllar	475
480	Thomas	Dennerby	480
481	Marcello	Frigério	471
482	John	Herdman	476
483	Kwang-min	Kim	478
484	Eli	Landsem	479
485	Kleiton	lima	467
486	Carolina	Morace	468
487	Silvia	Neid	473
488	Hope	Powell	470
489	Ricardo	Rozo	469
490	Norio	Sasaki	474
491	Tom	Sermanni	466
492	Pia	Sundhage	481
493	Ngozi Eucharia	Uche	477
494	James Kwesi	Appiah	497
495	Paulo	Bento	507
496	Fabio	Capello	508
497	Vicente	del Bosque	510
498	Didier	Deschamps	495
499	Volker	Finke	488
500	Vahid	Halilhodžić	482
501	Miguel	Herrera	504
502	Ottmar	Hitzfeld	511
503	Roy	Hodgson	494
504	Myung-bo	Hong	509
505	Stephen	Keshi	506
506	Jürgen	Klinsmann	512
507	Niko	Kovač	492
508	Sabri	Lamouchi	502
509	Joachim	Löw	496
510	José	Pékerman	490
511	Jorge Luis	Pinto	491
512	Ange	Postecoglou	484
513	Cesare	Prandelli	501
514	Carlos	Queiroz	500
515	Reinaldo	Rueda	493
516	Alejandro	Sabella	483
517	Jorge	Sampaoli	489
518	Fernando	Santos	498
519	Luiz Felipe	Scolari	487
520	Luis Fernando	Suárez	499
521	Safet	Sušić	486
522	Óscar	Tabárez	513
523	Louis	van Gaal	505
524	Marc	Wilmots	485
525	Alberto	Zaccheroni	503
526	Vanessa	Arauz	521
527	Philippe	Bergeroo	523
528	Leonardo	Cuéllar	527
529	Jill	Ellis	537
530	Carl	Enow	516
531	Wei	Hao	518
532	John	Herdman	517
533	Silvia	Neid	524
534	Edwin	Okon	530
535	Even	Pellerud	531
536	Ignacio	Quereda	533
537	Tony	Readings	529
538	Roger	Reijners	528
539	Mark	Sampson	522
540	Norio	Sasaki	526
541	Nuengrutai	Srathongvian	536
542	Alen	Stajcic	514
543	Pia	Sundhage	534
544	Fabián	Taborda	519
545	Clémentine	Touré	525
546	not applicable	Vadão	515
547	Amelia	Valverde	520
548	Martina	Voss-Tecklenburg	535
549	Deok-yeo	Yoon	532
550	Janne	Andersson	566
551	Stanislav	Cherchesov	560
552	Aliou	Cissé	562
553	Héctor	Cúper	546
554	Zlatko	Dalić	544
555	Didier	Deschamps	548
556	Ricardo	Gareca	557
557	Hernán Darío	Gómez	556
558	Heimir	Hallgrímsson	550
559	Åge	Hareide	545
560	Fernando	Hierro	565
561	Mladen	Krstajić	563
562	Joachim	Löw	549
563	Nabil	Maâloul	568
564	Roberto	Martínez	540
565	Adam	Nawałka	558
566	Akira	Nishino	552
567	Juan Carlos	Osorio	553
568	José	Pékerman	542
569	Vladimir	Petković	567
570	Juan Antonio	Pizzi	561
571	Carlos	Queiroz	551
572	Óscar	Ramírez	543
573	Hervé	Renard	554
574	Gernot	Rohr	555
575	Jorge	Sampaoli	538
576	Fernando	Santos	559
577	Tae-yong	Shin	564
578	Gareth	Southgate	547
579	Óscar	Tabárez	569
580	not applicable	Tite	541
581	Bert	van Marwijk	539
582	Milena	Bertolini	580
583	Carlos	Borrello	570
584	Thomas	Dennerby	585
585	Corinne	Diacre	578
586	Alain	Djeumfa	573
587	Desiree	Ellis	588
588	Jill	Ellis	593
589	Peter	Gerhardsson	591
590	Kenneth	Heiner-Møller	574
591	Xiuquan	Jia	576
592	Shelley	Kerr	587
593	José	Letelier	575
594	Hue	Menzies	581
595	Ante	Milicic	571
596	Phil	Neville	577
597	Tom	Sermanni	584
598	Martin	Sjögren	586
599	Nuengrutai	Srathongvian	592
600	Asako	Takakura	582
601	not applicable	Vadão	572
602	Jorge	Vilda	590
603	Martina	Voss-Tecklenburg	579
604	Sarina	Wiegman	583
605	Deok-yeo	Yoon	589
606	Otto	Addo	607
607	Gustavo	Alfaro	603
608	Diego	Alonso	624
609	Graham	Arnold	595
610	Paulo	Bento	619
611	Gregg	Berhalter	623
612	Aliou	Cissé	617
613	Zlatko	Dalić	601
614	Didier	Deschamps	605
615	Luis	Enrique	620
616	Hansi	Flick	606
617	John	Herdman	599
618	Kasper	Hjulmand	602
619	Jalel	Kadri	622
620	Roberto	Martínez	596
621	Gerardo	Martino	610
622	Czesław	Michniewicz	613
623	Hajime	Moriyasu	609
624	Rob	Page	625
625	Carlos	Queiroz	608
626	Walid	Regragui	611
627	Hervé	Renard	616
628	Félix	Sánchez	615
629	Fernando	Santos	614
630	Lionel	Scaloni	594
631	Rigobert	Song	598
632	Gareth	Southgate	604
633	Dragan	Stojković	618
634	Luis Fernando	Suárez	600
635	not applicable	Tite	597
636	Louis	van Gaal	612
637	Murat	Yakin	621
\.


--
-- Name: arbitres_id_arbitre_seq; Type: SEQUENCE SET; Schema: public; Owner: wcuser
--

SELECT pg_catalog.setval('public.arbitres_id_arbitre_seq', 1409, true);


--
-- Name: equipe_id_equipe_seq; Type: SEQUENCE SET; Schema: public; Owner: wcuser
--

SELECT pg_catalog.setval('public.equipe_id_equipe_seq', 625, true);


--
-- Name: faute_faute_id_seq; Type: SEQUENCE SET; Schema: public; Owner: wcuser
--

SELECT pg_catalog.setval('public.faute_faute_id_seq', 3175, true);


--
-- Name: joueur_id_joueur_seq; Type: SEQUENCE SET; Schema: public; Owner: wcuser
--

SELECT pg_catalog.setval('public.joueur_id_joueur_seq', 1, false);


--
-- Name: matchs_id_match_seq; Type: SEQUENCE SET; Schema: public; Owner: wcuser
--

SELECT pg_catalog.setval('public.matchs_id_match_seq', 1248, true);


--
-- Name: stafftechnique_id_staff_seq; Type: SEQUENCE SET; Schema: public; Owner: wcuser
--

SELECT pg_catalog.setval('public.stafftechnique_id_staff_seq', 637, true);


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
-- Name: selectionneur stafftechnique_pkey; Type: CONSTRAINT; Schema: public; Owner: wcuser
--

ALTER TABLE ONLY public.selectionneur
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
    ADD CONSTRAINT id_equipe_selectionneur FOREIGN KEY (id_selectionneur) REFERENCES public.selectionneur(id_staff);


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
-- Name: selectionneur stafftechnique_id_equipe_fkey; Type: FK CONSTRAINT; Schema: public; Owner: wcuser
--

ALTER TABLE ONLY public.selectionneur
    ADD CONSTRAINT stafftechnique_id_equipe_fkey FOREIGN KEY (id_equipe) REFERENCES public.equipe(id_equipe);


--
-- PostgreSQL database dump complete
--

