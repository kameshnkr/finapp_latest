--
-- PostgreSQL database dump
--

\restrict cHphBAZi4spjpp7EJJzbqmJxeATTdrI1DLqgsAUqMK2MkzoHefowt57LhcRjTpd

-- Dumped from database version 17.11 (fcae950)
-- Dumped by pg_dump version 17.9 (Homebrew)

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
-- Name: investments_account_assets; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.investments_account_assets (
    id bigint NOT NULL,
    user_id bigint NOT NULL,
    account_id bigint NOT NULL,
    asset_id bigint NOT NULL,
    status text DEFAULT 'ACTIVE'::text NOT NULL,
    version integer DEFAULT 1 NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT investments_account_assets_status_check CHECK ((status = ANY (ARRAY['ACTIVE'::text, 'ARCHIVED'::text])))
);


--
-- Name: investments_accounts; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.investments_accounts (
    id bigint NOT NULL,
    user_id bigint NOT NULL,
    name text NOT NULL,
    account_identifier text,
    broker_name text,
    status text DEFAULT 'ACTIVE'::text NOT NULL,
    version integer DEFAULT 1 NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT investments_accounts_status_check CHECK ((status = ANY (ARRAY['ACTIVE'::text, 'ARCHIVED'::text])))
);


--
-- Name: investments_asset_latest_prices; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.investments_asset_latest_prices (
    id bigint NOT NULL,
    asset_id bigint NOT NULL,
    price numeric(18,4) NOT NULL,
    price_date date NOT NULL,
    source text NOT NULL,
    synced_at timestamp with time zone DEFAULT now() NOT NULL,
    next_price_sync_after timestamp with time zone,
    version integer DEFAULT 1 NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT investments_asset_latest_prices_price_check CHECK ((price >= (0)::numeric))
);


--
-- Name: investments_asset_price_history; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.investments_asset_price_history (
    id bigint NOT NULL,
    asset_id bigint NOT NULL,
    price numeric(18,4) NOT NULL,
    price_date date NOT NULL,
    source text NOT NULL,
    synced_at timestamp with time zone DEFAULT now() NOT NULL,
    version integer DEFAULT 1 NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT investments_asset_price_history_price_check CHECK ((price >= (0)::numeric))
);


--
-- Name: investments_assets; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.investments_assets (
    id bigint NOT NULL,
    asset_class text NOT NULL,
    isin text NOT NULL,
    name text NOT NULL,
    symbol text,
    amfi_scheme_code bigint,
    status text DEFAULT 'ACTIVE'::text NOT NULL,
    version integer DEFAULT 1 NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT investments_assets_asset_class_check CHECK ((asset_class = ANY (ARRAY['MUTUAL_FUND'::text, 'STOCK'::text, 'ETF'::text, 'OTHER'::text]))),
    CONSTRAINT investments_assets_status_check CHECK ((status = ANY (ARRAY['ACTIVE'::text, 'ARCHIVED'::text])))
);


--
-- Name: investments_positions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.investments_positions (
    id bigint NOT NULL,
    user_id bigint NOT NULL,
    account_asset_id bigint NOT NULL,
    units numeric(20,6) DEFAULT 0 NOT NULL,
    version integer DEFAULT 1 NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT investments_positions_units_check CHECK ((units >= (0)::numeric))
);


--
-- Name: investments_pot_positions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.investments_pot_positions (
    id bigint NOT NULL,
    user_id bigint NOT NULL,
    pot_id bigint NOT NULL,
    account_asset_id bigint NOT NULL,
    units numeric(20,6) DEFAULT 0 NOT NULL,
    version integer DEFAULT 1 NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT investments_pot_positions_units_check CHECK ((units >= (0)::numeric))
);


--
-- Name: investments_pots; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.investments_pots (
    id bigint NOT NULL,
    user_id bigint NOT NULL,
    name text NOT NULL,
    description text,
    status text DEFAULT 'ACTIVE'::text NOT NULL,
    version integer DEFAULT 1 NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT investments_pots_status_check CHECK ((status = ANY (ARRAY['ACTIVE'::text, 'ARCHIVED'::text])))
);


--
-- Name: investments_transaction_pot_allocations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.investments_transaction_pot_allocations (
    id bigint NOT NULL,
    user_id bigint NOT NULL,
    transaction_id bigint NOT NULL,
    pot_id bigint NOT NULL,
    allocation_method text DEFAULT 'PERCENTAGE'::text NOT NULL,
    allocation_value numeric(6,3) NOT NULL,
    allocated_units numeric(20,6) NOT NULL,
    version integer DEFAULT 1 NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT investments_transaction_pot_allocations_allocated_units_check CHECK ((allocated_units > (0)::numeric)),
    CONSTRAINT investments_transaction_pot_allocations_allocation_method_check CHECK ((allocation_method = 'PERCENTAGE'::text)),
    CONSTRAINT investments_transaction_pot_allocations_allocation_value_check CHECK (((allocation_value > (0)::numeric) AND (allocation_value <= (100)::numeric)))
);


--
-- Name: investments_transactions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.investments_transactions (
    id bigint NOT NULL,
    user_id bigint NOT NULL,
    account_asset_id bigint NOT NULL,
    transaction_type text NOT NULL,
    units numeric(20,6) NOT NULL,
    price numeric(18,4) NOT NULL,
    amount numeric(18,2) NOT NULL,
    transaction_date date NOT NULL,
    source text DEFAULT 'STATEMENT'::text NOT NULL,
    source_reference_id text,
    fingerprint text,
    allocation_status text DEFAULT 'UNALLOCATED'::text NOT NULL,
    version integer DEFAULT 1 NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT investments_transactions_allocation_status_check CHECK ((allocation_status = ANY (ARRAY['UNALLOCATED'::text, 'ALLOCATED'::text]))),
    CONSTRAINT investments_transactions_amount_check CHECK ((amount >= (0)::numeric)),
    CONSTRAINT investments_transactions_price_check CHECK ((price >= (0)::numeric)),
    CONSTRAINT investments_transactions_source_check CHECK ((source = ANY (ARRAY['STATEMENT'::text, 'MANUAL'::text, 'RECONCILIATION'::text]))),
    CONSTRAINT investments_transactions_transaction_type_check CHECK ((transaction_type = ANY (ARRAY['BUY'::text, 'SELL'::text]))),
    CONSTRAINT investments_transactions_units_check CHECK ((units > (0)::numeric))
);


--
-- Name: investments_upload_jobs; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.investments_upload_jobs (
    id text NOT NULL,
    user_id bigint NOT NULL,
    account_id bigint NOT NULL,
    status text DEFAULT 'UPLOADING'::text NOT NULL,
    stage_message text,
    result jsonb,
    error_message text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT investments_upload_jobs_status_check CHECK ((status = ANY (ARRAY['UPLOADING'::text, 'PARSING'::text, 'VALIDATING'::text, 'RECONCILING'::text, 'AWAITING_CONFIRMATION'::text, 'SAVING'::text, 'COMPLETED'::text, 'FAILED'::text, 'REJECTED'::text])))
);


--
-- Name: investments_account_assets investments_account_assets_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.investments_account_assets
    ADD CONSTRAINT investments_account_assets_pkey PRIMARY KEY (id);


--
-- Name: investments_account_assets investments_account_assets_user_id_account_id_asset_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.investments_account_assets
    ADD CONSTRAINT investments_account_assets_user_id_account_id_asset_id_key UNIQUE (user_id, account_id, asset_id);


--
-- Name: investments_accounts investments_accounts_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.investments_accounts
    ADD CONSTRAINT investments_accounts_pkey PRIMARY KEY (id);


--
-- Name: investments_accounts investments_accounts_user_id_account_identifier_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.investments_accounts
    ADD CONSTRAINT investments_accounts_user_id_account_identifier_key UNIQUE (user_id, account_identifier);


--
-- Name: investments_accounts investments_accounts_user_id_name_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.investments_accounts
    ADD CONSTRAINT investments_accounts_user_id_name_key UNIQUE (user_id, name);


--
-- Name: investments_asset_latest_prices investments_asset_latest_prices_asset_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.investments_asset_latest_prices
    ADD CONSTRAINT investments_asset_latest_prices_asset_id_key UNIQUE (asset_id);


--
-- Name: investments_asset_latest_prices investments_asset_latest_prices_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.investments_asset_latest_prices
    ADD CONSTRAINT investments_asset_latest_prices_pkey PRIMARY KEY (id);


--
-- Name: investments_asset_price_history investments_asset_price_history_asset_id_price_date_source_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.investments_asset_price_history
    ADD CONSTRAINT investments_asset_price_history_asset_id_price_date_source_key UNIQUE (asset_id, price_date, source);


--
-- Name: investments_asset_price_history investments_asset_price_history_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.investments_asset_price_history
    ADD CONSTRAINT investments_asset_price_history_pkey PRIMARY KEY (id);


--
-- Name: investments_assets investments_assets_amfi_scheme_code_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.investments_assets
    ADD CONSTRAINT investments_assets_amfi_scheme_code_key UNIQUE (amfi_scheme_code);


--
-- Name: investments_assets investments_assets_isin_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.investments_assets
    ADD CONSTRAINT investments_assets_isin_key UNIQUE (isin);


--
-- Name: investments_assets investments_assets_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.investments_assets
    ADD CONSTRAINT investments_assets_pkey PRIMARY KEY (id);


--
-- Name: investments_positions investments_positions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.investments_positions
    ADD CONSTRAINT investments_positions_pkey PRIMARY KEY (id);


--
-- Name: investments_positions investments_positions_user_id_account_asset_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.investments_positions
    ADD CONSTRAINT investments_positions_user_id_account_asset_id_key UNIQUE (user_id, account_asset_id);


--
-- Name: investments_pot_positions investments_pot_positions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.investments_pot_positions
    ADD CONSTRAINT investments_pot_positions_pkey PRIMARY KEY (id);


--
-- Name: investments_pot_positions investments_pot_positions_user_id_pot_id_account_asset_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.investments_pot_positions
    ADD CONSTRAINT investments_pot_positions_user_id_pot_id_account_asset_id_key UNIQUE (user_id, pot_id, account_asset_id);


--
-- Name: investments_pots investments_pots_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.investments_pots
    ADD CONSTRAINT investments_pots_pkey PRIMARY KEY (id);


--
-- Name: investments_pots investments_pots_user_id_name_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.investments_pots
    ADD CONSTRAINT investments_pots_user_id_name_key UNIQUE (user_id, name);


--
-- Name: investments_transaction_pot_allocations investments_transaction_pot_a_user_id_transaction_id_pot_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.investments_transaction_pot_allocations
    ADD CONSTRAINT investments_transaction_pot_a_user_id_transaction_id_pot_id_key UNIQUE (user_id, transaction_id, pot_id);


--
-- Name: investments_transaction_pot_allocations investments_transaction_pot_allocations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.investments_transaction_pot_allocations
    ADD CONSTRAINT investments_transaction_pot_allocations_pkey PRIMARY KEY (id);


--
-- Name: investments_transactions investments_transactions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.investments_transactions
    ADD CONSTRAINT investments_transactions_pkey PRIMARY KEY (id);


--
-- Name: investments_upload_jobs investments_upload_jobs_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.investments_upload_jobs
    ADD CONSTRAINT investments_upload_jobs_pkey PRIMARY KEY (id);


--
-- Name: idx_investments_account_assets_account; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_investments_account_assets_account ON public.investments_account_assets USING btree (account_id);


--
-- Name: idx_investments_account_assets_asset; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_investments_account_assets_asset ON public.investments_account_assets USING btree (asset_id);


--
-- Name: idx_investments_accounts_user; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_investments_accounts_user ON public.investments_accounts USING btree (user_id);


--
-- Name: idx_investments_asset_price_history_asset; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_investments_asset_price_history_asset ON public.investments_asset_price_history USING btree (asset_id, price_date DESC);


--
-- Name: idx_investments_positions_account_asset; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_investments_positions_account_asset ON public.investments_positions USING btree (account_asset_id);


--
-- Name: idx_investments_pot_positions_account_asset; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_investments_pot_positions_account_asset ON public.investments_pot_positions USING btree (account_asset_id);


--
-- Name: idx_investments_pot_positions_pot; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_investments_pot_positions_pot ON public.investments_pot_positions USING btree (pot_id);


--
-- Name: idx_investments_pots_user; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_investments_pots_user ON public.investments_pots USING btree (user_id);


--
-- Name: idx_investments_tpa_pot; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_investments_tpa_pot ON public.investments_transaction_pot_allocations USING btree (pot_id);


--
-- Name: idx_investments_tpa_transaction; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_investments_tpa_transaction ON public.investments_transaction_pot_allocations USING btree (transaction_id);


--
-- Name: idx_investments_transactions_account_asset; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_investments_transactions_account_asset ON public.investments_transactions USING btree (account_asset_id);


--
-- Name: idx_investments_transactions_fingerprint; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_investments_transactions_fingerprint ON public.investments_transactions USING btree (user_id, fingerprint) WHERE (fingerprint IS NOT NULL);


--
-- Name: idx_investments_transactions_labeled_pagination; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_investments_transactions_labeled_pagination ON public.investments_transactions USING btree (user_id, transaction_date DESC, id DESC) WHERE (allocation_status = 'ALLOCATED'::text);


--
-- Name: idx_investments_transactions_unlabeled_pagination; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_investments_transactions_unlabeled_pagination ON public.investments_transactions USING btree (user_id, transaction_date DESC, id DESC) WHERE (allocation_status = 'UNALLOCATED'::text);


--
-- Name: idx_investments_upload_jobs_user; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_investments_upload_jobs_user ON public.investments_upload_jobs USING btree (user_id);


--
-- Name: investments_account_assets investments_account_assets_account_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.investments_account_assets
    ADD CONSTRAINT investments_account_assets_account_id_fkey FOREIGN KEY (account_id) REFERENCES public.investments_accounts(id) ON DELETE CASCADE;


--
-- Name: investments_account_assets investments_account_assets_asset_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.investments_account_assets
    ADD CONSTRAINT investments_account_assets_asset_id_fkey FOREIGN KEY (asset_id) REFERENCES public.investments_assets(id) ON DELETE CASCADE;


--
-- Name: investments_account_assets investments_account_assets_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.investments_account_assets
    ADD CONSTRAINT investments_account_assets_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- Name: investments_accounts investments_accounts_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.investments_accounts
    ADD CONSTRAINT investments_accounts_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- Name: investments_asset_latest_prices investments_asset_latest_prices_asset_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.investments_asset_latest_prices
    ADD CONSTRAINT investments_asset_latest_prices_asset_id_fkey FOREIGN KEY (asset_id) REFERENCES public.investments_assets(id) ON DELETE CASCADE;


--
-- Name: investments_asset_price_history investments_asset_price_history_asset_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.investments_asset_price_history
    ADD CONSTRAINT investments_asset_price_history_asset_id_fkey FOREIGN KEY (asset_id) REFERENCES public.investments_assets(id) ON DELETE CASCADE;


--
-- Name: investments_positions investments_positions_account_asset_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.investments_positions
    ADD CONSTRAINT investments_positions_account_asset_id_fkey FOREIGN KEY (account_asset_id) REFERENCES public.investments_account_assets(id) ON DELETE CASCADE;


--
-- Name: investments_positions investments_positions_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.investments_positions
    ADD CONSTRAINT investments_positions_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- Name: investments_pot_positions investments_pot_positions_account_asset_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.investments_pot_positions
    ADD CONSTRAINT investments_pot_positions_account_asset_id_fkey FOREIGN KEY (account_asset_id) REFERENCES public.investments_account_assets(id) ON DELETE CASCADE;


--
-- Name: investments_pot_positions investments_pot_positions_pot_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.investments_pot_positions
    ADD CONSTRAINT investments_pot_positions_pot_id_fkey FOREIGN KEY (pot_id) REFERENCES public.investments_pots(id) ON DELETE CASCADE;


--
-- Name: investments_pot_positions investments_pot_positions_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.investments_pot_positions
    ADD CONSTRAINT investments_pot_positions_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- Name: investments_pots investments_pots_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.investments_pots
    ADD CONSTRAINT investments_pots_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- Name: investments_transaction_pot_allocations investments_transaction_pot_allocations_pot_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.investments_transaction_pot_allocations
    ADD CONSTRAINT investments_transaction_pot_allocations_pot_id_fkey FOREIGN KEY (pot_id) REFERENCES public.investments_pots(id) ON DELETE CASCADE;


--
-- Name: investments_transaction_pot_allocations investments_transaction_pot_allocations_transaction_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.investments_transaction_pot_allocations
    ADD CONSTRAINT investments_transaction_pot_allocations_transaction_id_fkey FOREIGN KEY (transaction_id) REFERENCES public.investments_transactions(id) ON DELETE CASCADE;


--
-- Name: investments_transaction_pot_allocations investments_transaction_pot_allocations_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.investments_transaction_pot_allocations
    ADD CONSTRAINT investments_transaction_pot_allocations_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- Name: investments_transactions investments_transactions_account_asset_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.investments_transactions
    ADD CONSTRAINT investments_transactions_account_asset_id_fkey FOREIGN KEY (account_asset_id) REFERENCES public.investments_account_assets(id) ON DELETE CASCADE;


--
-- Name: investments_transactions investments_transactions_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.investments_transactions
    ADD CONSTRAINT investments_transactions_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- Name: investments_upload_jobs investments_upload_jobs_account_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.investments_upload_jobs
    ADD CONSTRAINT investments_upload_jobs_account_id_fkey FOREIGN KEY (account_id) REFERENCES public.investments_accounts(id) ON DELETE CASCADE;


--
-- Name: investments_upload_jobs investments_upload_jobs_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.investments_upload_jobs
    ADD CONSTRAINT investments_upload_jobs_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- PostgreSQL database dump complete
--

\unrestrict cHphBAZi4spjpp7EJJzbqmJxeATTdrI1DLqgsAUqMK2MkzoHefowt57LhcRjTpd

