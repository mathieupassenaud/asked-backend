SELECT rolname FROM pg_roles;

CREATE TABLE public.user ( 
    id   NAME NOT NULL DEFAULT current_setting('request.jwt.claim.sub', true) PRIMARY KEY,
    creation_timestamp    TIMESTAMP NOT NULL DEFAULT now(),
    first_name CHAR(50),
    gender  CHAR(1),
    birth Date,
    age integer,
    interested_for CHAR(1)[2],
    age_from integer,
    age_to integer,
    picture text,
    geog GEOGRAPHY(Point)
);
revoke all on public.user from "asked-rw";
-- ROW LEVEL SECURITY
-- only authenticated user can access data
ALTER TABLE public.user ENABLE ROW LEVEL SECURITY;
CREATE POLICY users_policy ON public.user
  USING (id = current_setting('request.jwt.claim.sub', true))
  WITH CHECK (id = current_setting('request.jwt.claim.sub', true));
  
-- A question : the main feature of this website. If a user changes his question, the question is still saved but not marked as "default"
-- we do not delete it because responses are linked to this table
CREATE TABLE public.question (
    ID  SERIAL PRIMARY KEY,
    creation_timestamp    TIMESTAMP NOT NULL DEFAULT now(),
    question TEXT,
    id_user NAME DEFAULT current_setting('request.jwt.claim.sub', true) REFERENCES public.user(id) ON DELETE CASCADE
);
ALTER TABLE public.question ENABLE ROW LEVEL SECURITY;
CREATE POLICY question_policy ON public.question
  USING (id_user = current_setting('request.jwt.claim.sub', true))
  WITH CHECK (id_user = current_setting('request.jwt.claim.sub', true));

-- A response to a question, by default not accepted
CREATE TABLE public.response (
    ID  SERIAL PRIMARY KEY,
    creation_timestamp    TIMESTAMP NOT NULL DEFAULT now(),
    id_user_from NAME NOT NULL DEFAULT current_setting('request.jwt.claim.sub', true) REFERENCES public.user ON DELETE CASCADE,
    id_question SERIAL REFERENCES public.question(id) ON DELETE CASCADE,
    response TEXT,
    accepted BOOLEAN DEFAULT null,
    viewed BOOLEAN DEFAULT false
);
ALTER TABLE public.response ENABLE ROW LEVEL SECURITY;
CREATE POLICY response_policy ON public.response
  USING (id_user_from = current_setting('request.jwt.claim.sub', true))
  WITH CHECK (id_user_from = current_setting('request.jwt.claim.sub', true));

-- A chat starts with an accepted response
CREATE TABLE public.message (
    ID SERIAL PRIMARY KEY,
    creation_timestamp TIMESTAMP NOT NULL DEFAULT now(),
    id_response SERIAL, FOREIGN KEY (id_response) REFERENCES public.response(id) ON DELETE CASCADE,
    id_user NAME DEFAULT current_setting('request.jwt.claim.sub', true), FOREIGN KEY (id_user) REFERENCES public.user ON DELETE CASCADE,
    unread BOOLEAN DEFAULT true,
    message TEXT
);
ALTER TABLE public.message ENABLE ROW LEVEL SECURITY;
CREATE POLICY message_policy ON public.message
  USING (id_user = current_setting('request.jwt.claim.sub', true))
  WITH CHECK (id_user = current_setting('request.jwt.claim.sub', true));

-- END OF DATA MODEL
-- Let's begin with APIs

-- a view for a random question. Because this user is in an environment variable (thanks to postgrest), the filter directly applies.
--
-- With postgis, we get the closest new questions
--
-- edit : you never have to anwser to your own question
CREATE VIEW public.random_question AS
SELECT public.user.id AS user_id, first_name, picture, age,
public.question.id AS question_id,
public.question.question,
max(public.question.creation_timestamp),
ST_Distance( geog, (select geog from public.user where id=current_setting('request.jwt.claim.sub', true) limit 1) ) / 1000 AS distance
FROM public.user
JOIN public.question ON public.user.id=public.question.id_user
LEFT JOIN public.response ON public.question.id=public.response.id_question
WHERE public.question.id NOT IN ( SELECT id_question from public.response where id_user_from=current_setting('request.jwt.claim.sub', true))
AND public.question.id_user NOT IN (current_setting('request.jwt.claim.sub', true))
AND public.user.id NOT IN ( SELECT id_user_from  from public.response JOIN public.question ON public.question.id=public.response.id_question WHERE accepted=true AND public.question.id_user=current_setting('request.jwt.claim.sub', true))
AND gender IN (SELECT unnest(interested_for) from public.user where id=current_setting('request.jwt.claim.sub', true))
AND age
            BETWEEN (SELECT age_from from public.user where id=current_setting('request.jwt.claim.sub', true)) 
            AND (SELECT age_to from public.user where id=current_setting('request.jwt.claim.sub', true))
GROUP BY public.user.id, public.question.id
ORDER BY ST_Distance( geog, (select geog from public.user where id=current_setting('request.jwt.claim.sub', true) limit 1) )
LIMIT 1;

GRANT SELECT ON public.random_question TO asked;

-- An API to register a new user
--
-- Table has a row level security
--
CREATE VIEW public.me AS
SELECT id, gender, first_name, picture, birth, age, interested_for, age_from, age_to, geog from public.user
WHERE id=current_setting('request.jwt.claim.sub', true);
GRANT ALL ON public.me TO "asked-rw";


-- An API for questions
--
--
CREATE VIEW public.user_question AS
SELECT id, question 
FROM public.question
WHERE id_user=current_setting('request.jwt.claim.sub', true)
ORDER BY public.question.creation_timestamp DESC;

GRANT ALL ON public.user_question TO asked;

-- An API for response
-- 
CREATE VIEW public.user_response AS
SELECT id_user_from, id_question, response
FROM public.response;

GRANT INSERT ON public.user_response TO asked;

-- An API to get answers
--
--
CREATE VIEW public.new_responses AS
SELECT response.id AS id, response, question, 
public.user.id AS user_id, first_name, picture, age,
ST_Distance( public.user.geog, (select geog from public.user where id=current_setting('request.jwt.claim.sub', true) limit 1) ) / 1000 AS distance,
accepted
FROM public.response
JOIN public.question ON public.question.id=public.response.id_question
JOIN public.user ON public.user.id=public.response.id_user_from
WHERE accepted IS NULL
AND public.question.id_user=current_setting('request.jwt.claim.sub', true)
AND public.response.response IS NOT NULL;

GRANT SELECT ON public.new_responses TO asked;

-- accept a response
--
CREATE VIEW public.accept_response AS
SELECT response.id AS id, accepted, viewed
FROM public.response;

GRANT UPDATE ON public.accept_response TO asked;

-- An API to get accepted answers
--
--
CREATE VIEW public.accepted_responses AS
SELECT response.id AS id, response, question, first_name, picture,
accepted
FROM public.response
JOIN public.question ON public.question.id=public.response.id_question
JOIN public.user ON public.question.id_user=public.user.id
WHERE accepted IS true AND viewed IS false
AND public.response.id_user_from=current_setting('request.jwt.claim.sub', true);

GRANT SELECT ON public.accepted_responses TO asked;

-- An API to list conversations
--
-- "COALESCE" is similar to "IFNULL"
CREATE VIEW public.chats AS
SELECT response.id AS id, response, question, first_name, picture, age,
accepted, COALESCE(unread, false) AS unread
FROM public.response
JOIN public.question ON public.question.id=public.response.id_question
JOIN public.user ON public.question.id_user=public.user.id OR public.response.id_user_from=public.user.id
LEFT JOIN public.message ON public.response.id=public.message.id_response AND public.message.id_user<>current_setting('request.jwt.claim.sub', true)
WHERE accepted IS true
AND (public.response.id_user_from=current_setting('request.jwt.claim.sub', true)
OR public.question.id_user=current_setting('request.jwt.claim.sub', true)  )
AND public.user.id<>current_setting('request.jwt.claim.sub', true)
GROUP BY response.id, question, first_name, picture, unread, birth, age;

GRANT SELECT ON public.chats TO asked;

drop view public.chats;

-- An API for conversations
--
CREATE VIEW public.conversation AS
SELECT message, first_name, message.creation_timestamp, message.unread, id_response
FROM public.message
JOIN public.user ON public.message.id_user=public.user.id
JOIN public.response ON public.response.id=public.message.id_response
JOIN public.question ON public.question.id=public.response.id_question
WHERE (public.response.id_user_from=current_setting('request.jwt.claim.sub', true)
OR public.question.id_user=current_setting('request.jwt.claim.sub', true))
ORDER BY message.creation_timestamp;

GRANT SELECT, INSERT ON public.conversation TO asked;

-- An api to push a message in a conversation
-- This is a little different. We have to verify that the user is concerned by the conversation
-- it seams : 
-- - it is his question
-- - or his response had been accepted
--
CREATE FUNCTION public.post_message(id_response integer, message TEXT)
RETURNS void
AS $$
BEGIN
    IF EXISTS(SELECT *
    FROM public.response
    JOIN public.question ON public.question.id=public.response.id_question
    WHERE (public.response.id_user_from=current_setting('request.jwt.claim.sub', true)
    OR public.question.id_user=current_setting('request.jwt.claim.sub', true))
    AND response.id=id_response)    
     THEN
        INSERT INTO public.message (id_response, message) VALUES (id_response, message);
    END IF;
END;
$$ LANGUAGE 'plpgsql';

-- An api to mark messages "read"
--
--
CREATE FUNCTION set_read(id_chat integer)
RETURNS void
AS $$
BEGIN
    IF EXISTS(SELECT *
    FROM public.response
    JOIN public.question ON public.question.id=public.response.id_question
    WHERE (public.response.id_user_from=current_setting('request.jwt.claim.sub', true)
    OR public.question.id_user=current_setting('request.jwt.claim.sub', true))
    AND response.id=id_chat)    
     THEN
        UPDATE public.message SET unread=false WHERE 
        public.message.id_response=id_chat
        AND public.message.id_user<>current_setting('request.jwt.claim.sub', true);
    END IF;
END;
$$ LANGUAGE 'plpgsql';
