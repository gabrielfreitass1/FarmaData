"""Painel Analítico FarmaData — Inteligência de Dispensação de Medicamentos.

Responde à pergunta central de gestão formulada na E1 e expandida na E3:
Análise territorial, per capita (IBGE), sazonalidade climática (INMET) e
distribuição etária e clínica (CID-10/IBGE).
"""

import os
import streamlit as st
import pandas as pd
import plotly.express as px
import plotly.graph_objects as go
from sqlalchemy import create_engine, text

# Configuração da página
st.set_page_config(
    page_title="FarmaData — Painel Analítico",
    page_icon="💊",
    layout="wide",
    initial_sidebar_state="expanded",
)

# Garantir driver psycopg2 explícito na URL
raw_db_url = os.environ.get(
    "DATABASE_URL", "postgresql+psycopg2://postgres:postgres@localhost:5432/farmadata"
)
if raw_db_url.startswith("postgresql://"):
    DATABASE_URL = raw_db_url.replace("postgresql://", "postgresql+psycopg2://", 1)
elif raw_db_url.startswith("postgres://"):
    DATABASE_URL = raw_db_url.replace("postgres://", "postgresql+psycopg2://", 1)
else:
    DATABASE_URL = raw_db_url


@st.cache_resource
def get_engine():
    try:
        engine = create_engine(DATABASE_URL, pool_pre_ping=True, connect_args={"connect_timeout": 3})
        # Test connection
        with engine.connect() as conn:
            conn.execute(text("SELECT 1"))
        return engine, None
    except Exception as e:
        return None, str(e)


engine, db_conn_error = get_engine()

# -----------------------------------------------------------------------------
# Verificação de Freshness do Modelo Dimensional (ADR-005 / Issue #29)
# -----------------------------------------------------------------------------
freshness_status = None
freshness_msg = None
if engine:
    try:
        with engine.connect() as conn:
            # Chama a função canônica do sql/13_controle_build.sql
            status = conn.execute(text(
                "SELECT status FROM checar_freshness('fato_venda_medicamento', 24, 48)"
            )).scalar()
            freshness_status = status
            if status == "ERRO":
                st.error("🚨 **SLA de Freshness violado (ERRO):** A tabela `fato_venda_medicamento` está desatualizada há mais de 48h ou nunca foi construída.")
                st.stop()
            elif status == "WARN":
                st.warning("⚠️ **Aviso de Freshness (WARN):** Carga pendente há mais de 24h sem reconstrução da `fato_venda_medicamento`.")
    except Exception as e:
        # Se checar_freshness falhar (ex.: função não migrada), apenas exibe aviso técnico discreto
        st.sidebar.caption(f"Verificação de freshness: {e}")


# -----------------------------------------------------------------------------
# Consultas em Cache (com fallback e rastreabilidade explícita de erro)
# -----------------------------------------------------------------------------
@st.cache_data(ttl=3600)
def carregar_dados_per_capita():
    if engine:
        try:
            sql = """
            SELECT m.nome_municipio, m.sigla_uf,
                   p.populacao,
                   SUM(f.quantidade_vendida) AS total_vendido,
                   ROUND((SUM(f.quantidade_vendida) / p.populacao) * 1000, 2) AS vendas_por_1000_hab
            FROM fato_venda_medicamento f
            JOIN dim_municipio m ON f.sk_municipio = m.sk_municipio
            JOIN ibge_populacao_municipio p ON m.id_municipio = p.id_municipio
            WHERE p.populacao > 30000
            GROUP BY m.nome_municipio, m.sigla_uf, p.populacao
            ORDER BY vendas_por_1000_hab DESC
            LIMIT 100;
            """
            return pd.read_sql(sql, engine), False, None
        except Exception as e:
            return None, True, str(e)

    return None, True, db_conn_error or "Banco de dados inacessível"


def mock_per_capita():
    # Mock de alta fidelidade representativo do domínio (caso DB esteja offline)
    return pd.DataFrame({
        "nome_municipio": ["Brasília", "São Paulo", "Rio de Janeiro", "Belo Horizonte", "Curitiba",
                           "Porto Alegre", "Goiânia", "Campinas", "Ribeirão Preto", "Florianópolis",
                           "Maringá", "Londrina", "Caxias do Sul", "Uberlândia", "Sorocaba"],
        "sigla_uf": ["DF", "SP", "RJ", "MG", "PR", "RS", "GO", "SP", "SP", "SC", "PR", "PR", "RS", "MG", "SP"],
        "populacao": [3055149, 12396372, 6775561, 2530701, 1963726, 1492530, 1555626, 1223237, 720116, 516524,
                      436472, 580870, 523716, 706597, 695328],
        "total_vendido": [4850000, 16500000, 8900000, 3900000, 3300000, 2700000, 2400000, 2100000, 1500000, 1200000,
                          1050000, 1350000, 1150000, 1450000, 1300000],
        "vendas_por_1000_hab": [1587.48, 1331.03, 1313.54, 1541.07, 1680.48, 1808.99, 1542.79, 1716.76, 2082.99, 2323.22,
                                2405.65, 2324.10, 2195.85, 2052.09, 1869.62],
    })


@st.cache_data(ttl=3600)
def carregar_dados_clima(uf_selecionada):
    if engine:
        try:
            sql = """
            WITH mensal AS (
              SELECT c.sigla_uf, f.id_periodo, c.temp_media_c, c.precipitacao_media_mm, SUM(f.quantidade_vendida) AS vol
              FROM fato_venda_medicamento f
              JOIN dim_municipio m ON m.sk_municipio = f.sk_municipio
              JOIN clima_mensal_uf c ON c.sigla_uf = m.sigla_uf AND c.id_periodo = f.id_periodo
              WHERE f.eh_antimicrobiano AND (:uf = 'TODAS' OR c.sigla_uf = :uf)
              GROUP BY c.sigla_uf, f.id_periodo, c.temp_media_c, c.precipitacao_media_mm
            )
            SELECT id_periodo, ROUND(AVG(temp_media_c)::numeric, 1) as temp_media_c,
                   ROUND(AVG(precipitacao_media_mm)::numeric, 1) as precipitacao_media_mm,
                   SUM(vol) as volume_antimicrobianos
            FROM mensal
            GROUP BY id_periodo
            ORDER BY id_periodo;
            """
            return pd.read_sql(text(sql), engine, params={"uf": uf_selecionada}), False, None
        except Exception as e:
            return None, True, str(e)

    return None, True, db_conn_error or "Banco de dados inacessível"


def mock_clima():
    periodos = [f"2020{m:02d}" for m in range(1, 13)]
    temps = [25.5, 25.2, 24.1, 22.0, 18.5, 16.2, 15.8, 17.5, 20.1, 22.4, 23.8, 24.9]
    chuva = [240, 210, 180, 80, 50, 40, 20, 25, 65, 120, 190, 230]
    vols = [480000, 470000, 510000, 590000, 780000, 890000, 920000, 850000, 690000, 580000, 520000, 490000]

    return pd.DataFrame({
        "id_periodo": periodos,
        "temp_media_c": temps,
        "precipitacao_media_mm": chuva,
        "volume_antimicrobianos": vols,
    })


@st.cache_data(ttl=3600)
def carregar_dados_clinicos():
    if engine:
        try:
            sql = """
            SELECT COALESCE(c.codigo, 'SEM_CID') as cid_codigo,
                   COALESCE(c.descricao, 'Não informado / Receita de controle geral') as cid_descricao,
                   SUM(f.quantidade_vendida) as volume_dispensado
            FROM fato_venda_medicamento f
            LEFT JOIN cid10 c ON f.codigo_cid10 = c.codigo
            WHERE f.eh_antimicrobiano
            GROUP BY c.codigo, c.descricao
            ORDER BY volume_dispensado DESC
            LIMIT 10;
            """
            return pd.read_sql(sql, engine), False, None
        except Exception as e:
            return None, True, str(e)

    return None, True, db_conn_error or "Banco de dados inacessível"


def mock_clinicos():
    return pd.DataFrame({
        "cid_codigo": ["J01", "J02", "J03", "J06", "N39", "J20", "L03", "K04", "J18", "H66"],
        "cid_descricao": [
            "Sinusite aguda",
            "Faringite aguda",
            "Amigdalite aguda",
            "Infecções agudas das vias aéreas superiores",
            "Infecção do trato urinário de localização não especificada",
            "Bronquite aguda",
            "Celulite (infecção bacteriana de pele)",
            "Doenças da polpa e dos tecidos periapicais",
            "Pneumonia por micro-organismo não especificado",
            "Otite média supurativa e não especificada",
        ],
        "volume_dispensado": [850000, 720000, 680000, 640000, 580000, 490000, 390000, 320000, 290000, 240000],
    })


# -----------------------------------------------------------------------------
# Interface e Layout
# -----------------------------------------------------------------------------
st.title("💊 FarmaData — Inteligência Analítica de Dispensação")
st.markdown(
    "> **Pergunta Central:** *Quais classes terapêuticas e municípios concentram a demanda, e de que forma "
    "indicadores demográficos per capita (IBGE), dinâmicas meteorológicas sazonais (INMET) e diagnósticos clínicos (CID-10) "
    "explicam as anomalias e os picos de consumo?*"
)

# Carregamento da Aba 1 para filtros globais
df_per_capita, is_mock1, err1 = carregar_dados_per_capita()
if is_mock1:
    df_per_capita = mock_per_capita()

# Barra lateral com filtros
st.sidebar.header("🎯 Filtros Globais")
ufs_disponiveis = ["TODAS"] + sorted(list(df_per_capita["sigla_uf"].unique()))
uf_filtro = st.sidebar.selectbox("Filtrar por Unidade Federativa (UF):", ufs_disponiveis)

# Abas temáticas
tab1, tab2, tab3 = st.tabs([
    "📍 1. Territorial & Per Capita (IBGE)",
    "❄️ 2. Sazonalidade Climática (INMET)",
    "🩺 3. Demografia & Clínica (CID-10)",
])

# -----------------------------------------------------------------------------
# ABA 1: Territorial e Per Capita
# -----------------------------------------------------------------------------
with tab1:
    st.subheader("Dispensação Absoluta vs. Demanda per Capita Municipal")
    st.write(
        "O cruzamento com os dados censitários do IBGE permite eliminar a ilusão de volume provocada "
        "por metrópoles e identificar municípios com consumo atipicamente elevado por habitante."
    )

    if is_mock1:
        st.warning(
            "⚠️ **Modo Demonstração ativo:** Não foi possível consultar o banco de dados. "
            "Exibindo dados simulados de contingência."
        )
        if err1:
            with st.expander("Ver detalhes técnicos do erro"):
                st.code(err1, language="text")

    df_filtered_tab1 = df_per_capita.copy()
    if uf_filtro != "TODAS":
        df_filtered_tab1 = df_filtered_tab1[df_filtered_tab1["sigla_uf"] == uf_filtro]

    col1, col2 = st.columns(2)

    with col1:
        st.markdown("**Top 10 Municípios em Volume Absoluto de Vendas**")
        top_abs = df_filtered_tab1.sort_values(by="total_vendido", ascending=False).head(10)
        fig_abs = px.bar(
            top_abs,
            x="total_vendido",
            y="nome_municipio",
            orientation="h",
            color="sigla_uf",
            labels={"total_vendido": "Total de Unidades Dispensadas", "nome_municipio": "Município"},
        )
        fig_abs.update_layout(yaxis={"autorange": "reversed"}, height=350)
        st.plotly_chart(fig_abs, use_container_width=True)

    with col2:
        st.markdown("**Top 10 Municípios por Taxa per Capita (Vendas / 1.000 hab)**")
        top_pc = df_filtered_tab1.sort_values(by="vendas_por_1000_hab", ascending=False).head(10)
        fig_pc = px.bar(
            top_pc,
            x="vendas_por_1000_hab",
            y="nome_municipio",
            orientation="h",
            color="vendas_por_1000_hab",
            color_continuous_scale="Viridis",
            labels={"vendas_por_1000_hab": "Vendas por 1.000 Hab.", "nome_municipio": "Município"},
        )
        fig_pc.update_layout(yaxis={"autorange": "reversed"}, height=350)
        st.plotly_chart(fig_pc, use_container_width=True)

    st.markdown("#### Detalhamento Municipal")
    st.dataframe(
        df_filtered_tab1[["nome_municipio", "sigla_uf", "populacao", "total_vendido", "vendas_por_1000_hab"]],
        use_container_width=True,
    )

# -----------------------------------------------------------------------------
# ABA 2: Sazonalidade Climática (INMET)
# -----------------------------------------------------------------------------
with tab2:
    st.subheader("Correlação entre Temperatura e Dispensação de Antimicrobianos")
    st.write(
        "A série histórica de temperatura média e precipitação do INMET comprova a hipótese da sazonalidade: "
        "a queda de temperatura durante o inverno induz picos acentuados no consumo de antibióticos."
    )

    df_clima, is_mock2, err2 = carregar_dados_clima(uf_filtro)
    if is_mock2:
        df_clima = mock_clima()
        st.warning(
            "⚠️ **Modo Demonstração ativo:** Não foi possível consultar o banco de dados. "
            "Exibindo dados simulados de contingência."
        )
        if err2:
            with st.expander("Ver detalhes técnicos do erro"):
                st.code(err2, language="text")

    col_clima1, col_clima2 = st.columns([2, 1])

    with col_clima1:
        # Gráfico de eixo duplo: Volume de antimicrobianos x Temperatura
        fig_dual = go.Figure()
        fig_dual.add_trace(go.Bar(
            x=df_clima["id_periodo"],
            y=df_clima["volume_antimicrobianos"],
            name="Volume de Antimicrobianos",
            marker_color="rgba(55, 128, 191, 0.7)",
            yaxis="y",
        ))
        fig_dual.add_trace(go.Scatter(
            x=df_clima["id_periodo"],
            y=df_clima["temp_media_c"],
            name="Temperatura Média (°C)",
            mode="lines+markers",
            line=dict(color="firebrick", width=3),
            yaxis="y2",
        ))
        fig_dual.update_layout(
            title="Evolução Mensal: Demanda de Antimicrobianos vs. Temperatura Média",
            xaxis=dict(title="Período (Ano/Mês)"),
            yaxis=dict(title="Unidades Dispensadas", side="left"),
            yaxis2=dict(title="Temperatura (°C)", overlaying="y", side="right"),
            height=400,
            legend=dict(x=0.01, y=0.99),
        )
        st.plotly_chart(fig_dual, use_container_width=True)

    with col_clima2:
        # Dispersão e correlação
        fig_scatter = px.scatter(
            df_clima,
            x="temp_media_c",
            y="volume_antimicrobianos",
            trendline="ols",
            title="Dispersão: Temp. vs Volume",
            labels={"temp_media_c": "Temp. Média (°C)", "volume_antimicrobianos": "Volume Dispensado"},
        )
        fig_scatter.update_layout(height=400)
        st.plotly_chart(fig_scatter, use_container_width=True)

    corr = df_clima["temp_media_c"].corr(df_clima["volume_antimicrobianos"])
    st.metric(
        label="Coeficiente de Correlação de Pearson (Temperatura x Antimicrobianos)",
        value=f"{corr:.2f}",
        delta="Correlação Inversa Forte" if corr < -0.7 else "Correlação Moderada",
        delta_color="inverse",
    )

# -----------------------------------------------------------------------------
# ABA 3: Demografia e Clínica (CID-10)
# -----------------------------------------------------------------------------
with tab3:
    st.subheader("Indicação Diagnóstica (CID-10) e Perfil de Prescrição")
    st.write(
        "A base pública do SNGPC restringe a obrigatoriedade de CID-10 e idade aos antimicrobianos. "
        "Abaixo mapeamos os diagnósticos que concentram o uso clínico dessas substâncias."
    )

    df_cid, is_mock3, err3 = carregar_dados_clinicos()
    if is_mock3:
        df_cid = mock_clinicos()
        st.warning(
            "⚠️ **Modo Demonstração ativo:** Não foi possível consultar o banco de dados. "
            "Exibindo dados simulados de contingência."
        )
        if err3:
            with st.expander("Ver detalhes técnicos do erro"):
                st.code(err3, language="text")

    col_cid1, col_cid2 = st.columns([3, 2])

    with col_cid1:
        fig_cid = px.bar(
            df_cid,
            x="volume_dispensado",
            y="cid_descricao",
            orientation="h",
            labels={"volume_dispensado": "Volume Dispensado", "cid_descricao": "Condição Diagnóstica (CID-10)"},
            color="volume_dispensado",
            color_continuous_scale="Teal",
        )
        fig_cid.update_layout(yaxis={"autorange": "reversed"}, height=420)
        st.plotly_chart(fig_cid, use_container_width=True)

    with col_cid2:
        st.markdown("**Classificação por Código CID-10**")
        st.dataframe(
            df_cid[["cid_codigo", "cid_descricao", "volume_dispensado"]],
            use_container_width=True,
            height=380,
        )

st.markdown("---")
st.caption(
    "FarmaData — Projeto Integrado SBD2 / Universidade de Brasília (UnB). "
    "Dados: SNGPC/Anvisa, IBGE (Censo/População), INMET (Estadas Meteorológicas) e DATASUS (CID-10)."
)
