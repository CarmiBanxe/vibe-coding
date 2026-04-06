@echo off
chcp 65001 >nul
title Sync Vibe-Coding Project

echo ============================================
echo   СИНХРОНИЗАЦИЯ ПРОЕКТА VIBE-CODING
echo ============================================
echo.

REM --- Путь к папке проекта ---
set PROJECT_DIR=%USERPROFILE%\vibe-coding

REM --- Проверяем, есть ли уже папка проекта ---
if not exist "%PROJECT_DIR%" (
    echo Первый запуск! Скачиваю проект с GitHub...
    echo.
    cd /d "%USERPROFILE%"
    git clone https://github.com/CarmiBanxe/vibe-coding.git
    if errorlevel 1 (
        echo.
        echo ОШИБКА: Не удалось скачать проект.
        echo Проверь подключение к интернету и настройки Git.
        pause
        exit /b 1
    )
    echo.
    echo Проект успешно скачан!
) else (
    echo Обновляю проект...
    echo.
    cd /d "%PROJECT_DIR%"
    git pull origin main
    if errorlevel 1 (
        echo.
        echo ОШИБКА: Не удалось обновить проект.
        echo Попробуй удалить папку %PROJECT_DIR% и запустить sync.bat заново.
        pause
        exit /b 1
    )
    echo.
    echo Проект успешно обновлён!
)

echo.
echo ============================================
echo   Папка проекта: %PROJECT_DIR%
echo ============================================
echo.
echo Открываю в VS Code...
code "%PROJECT_DIR%"

echo.
echo Готово! Это окно можно закрыть.
timeout /t 5
