#define SDL_MAIN_HANDLED
#include <SDL2/SDL.h>
#include <SDL2/SDL_opengles2.h>
#include <stdio.h>

int main(void)
{
    SDL_Window *window = NULL;
    SDL_GLContext context = NULL;
    Uint32 started;
    int running = 1;

    SDL_SetMainReady();
    SDL_GL_SetAttribute(SDL_GL_CONTEXT_PROFILE_MASK, SDL_GL_CONTEXT_PROFILE_ES);
    SDL_GL_SetAttribute(SDL_GL_CONTEXT_MAJOR_VERSION, 3);
    SDL_GL_SetAttribute(SDL_GL_CONTEXT_MINOR_VERSION, 0);
    SDL_GL_SetAttribute(SDL_GL_DOUBLEBUFFER, 1);

    if (SDL_Init(SDL_INIT_VIDEO | SDL_INIT_EVENTS) < 0) {
        fprintf(stderr, "xios-sdl2-smoke: SDL_Init: %s\n", SDL_GetError());
        return 1;
    }

    window = SDL_CreateWindow("SDL2 on Xios",
                              SDL_WINDOWPOS_CENTERED, SDL_WINDOWPOS_CENTERED,
                              960, 640,
                              SDL_WINDOW_OPENGL | SDL_WINDOW_RESIZABLE |
                                  SDL_WINDOW_ALLOW_HIGHDPI);
    if (!window) {
        fprintf(stderr, "xios-sdl2-smoke: SDL_CreateWindow: %s\n", SDL_GetError());
        SDL_Quit();
        return 2;
    }

    context = SDL_GL_CreateContext(window);
    if (!context) {
        fprintf(stderr, "xios-sdl2-smoke: SDL_GL_CreateContext: %s\n", SDL_GetError());
        SDL_DestroyWindow(window);
        SDL_Quit();
        return 3;
    }

    SDL_GL_SetSwapInterval(1);
    fprintf(stderr,
            "XIOS_SDL_SMOKE_READY api=SDL2 driver=%s renderer=%s version=%s touch=%d\n",
            SDL_GetCurrentVideoDriver(),
            (const char *)glGetString(GL_RENDERER),
            (const char *)glGetString(GL_VERSION),
            SDL_GetNumTouchDevices());

    started = SDL_GetTicks();
    while (running && SDL_GetTicks() - started < 120000) {
        SDL_Event event;
        int width = 1;
        int height = 1;
        float phase = (float)((SDL_GetTicks() - started) % 6000) / 6000.0f;

        while (SDL_PollEvent(&event)) {
            if (event.type == SDL_QUIT ||
                (event.type == SDL_KEYDOWN && event.key.keysym.sym == SDLK_ESCAPE)) {
                running = 0;
            }
        }

        SDL_GL_GetDrawableSize(window, &width, &height);
        glViewport(0, 0, width, height);
        glClearColor(0.06f + phase * 0.16f, 0.18f, 0.48f - phase * 0.18f, 1.0f);
        glClear(GL_COLOR_BUFFER_BIT);
        SDL_GL_SwapWindow(window);
    }

    SDL_GL_DeleteContext(context);
    SDL_DestroyWindow(window);
    SDL_Quit();
    return 0;
}
