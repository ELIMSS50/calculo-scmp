# Imagen base de Perl
FROM perl:5.38

# Directorio de trabajo dentro del contenedor
WORKDIR /app

# Copiar dependencias primero (optimiza caché de Docker)
COPY cpanfile .

# Instalar dependencias
RUN cpanm --installdeps . --notest

# Copiar todo el código
COPY . .

# Puerto que expone el microservicio
EXPOSE 3000

# Comando para arrancar en producción
CMD ["hypnotoad", "-f", "script/calculo_scmp"]
