#include <cstdio>
#include <fstream>
#include <functional>
#include <iostream>
#include <sstream>
#include <stdexcept>
#include <string>
#include <vector>
#include <unistd.h>

using namespace std;
namespace boost {
string is_any_of(const char *s) { return s; }
void split(vector<string> &out, const string &s, const string &separators) {
    out.clear();
    size_t start = 0, end;
    while ((end = s.find_first_of(separators, start)) != string::npos) {
        out.push_back(s.substr(start, end - start));
        start = end + 1;
    }
    out.push_back(s.substr(start));
}
template<typename T> T lexical_cast(const string &s) {
    T value;
    istringstream input(s);
    if (!(input >> value)) throw runtime_error("invalid fixture number");
    return value;
}
}
template<typename T> string ofToString(T value) { ostringstream s; s << value; return s.str(); }
unsigned long long now_us = 1000;
unsigned long long ofGetSystemTimeMicros() { return now_us; }
int ofGetWindowWidth() { return 100; }
int ofGetWindowHeight() { return 100; }
bool usesDolbyVisionTransport() { return false; }

struct ofxRPI4Window {
    static int bit_depth, colorspace_on, shader_init, isDoVi, is_std_DoVi;
    struct AVI { int output_format = 0, rgb_quant_range = 2, max_bpc = 8; };
    static AVI avi_info;
    // COLOUR_SHADER_PREDICATE
};
int ofxRPI4Window::bit_depth = 8, ofxRPI4Window::colorspace_on = 1;
int ofxRPI4Window::shader_init = 0, ofxRPI4Window::isDoVi = 0, ofxRPI4Window::is_std_DoVi = 0;
ofxRPI4Window::AVI ofxRPI4Window::avi_info;

struct Image {
    void grabScreen(int, int, int, int) {}
    bool isAllocated() { return false; }
    void draw(int, int, int, int) {}
    void save(const string &) {}
};
class ofApp {
public:
    string tmp_dir, path, p_name, m_name, draw_type, text_to_write, img_file, name;
    string previous_image, previous_draw_type, image_save, movie_name;
    int i = 0, frame = 0, frame_to_draw = 0, entered = 0, open_file = 1;
    int source_max = 255, source_range = 0, bits = 8, img_rotate = 0;
    int dim1 = 0, dim2 = 0, resolution = 0, red = 0, green = 0, blue = 0;
    int redb = 0, greenb = 0, blueb = 0, position_x = 0, position_y = 0;
    int loop_count = 0, save_images = 0, first_done = 0, n_frame = 0, to_draw = 0;
    unsigned long long last_frame_time = 0, arr_frame_time[8] = {}, arr_frame_duration[8] = {};
    int n_draw[8] = {}, arr_red[8][8] = {}, arr_green[8][8] = {}, arr_blue[8][8] = {};
    int arr_redbg[8][8] = {}, arr_greenbg[8][8] = {}, arr_bluebg[8][8] = {};
    int arr_draw[8][8] = {}, arr_dim1[8][8] = {}, arr_dim2[8][8] = {};
    int arr_posx[8][8] = {}, arr_posy[8][8] = {}, arr_resolution[8][8] = {};
    int arr_rotate[8][8] = {}, arr_bits[8][8] = {}, arr_source_max[8][8] = {}, arr_source_range[8][8] = {};
    string arr_text[8][8], arr_image[8][8], arr_name[8];
    Image img;
    vector<int> drawn;
    function<void()> after_first_draw;
    void update();
    void draw();
    void set_values();
    void log(const string &) {}
    void restoreBackground() {} // Colour replay is exercised by renderer_precision.
    void setBackground(int, int, int) {}
    void setColor(int, int, int) {}
    void shader_begin(int) {}
    void shader_end(int) {}
    void fbo_allocate() {}
    void dovi_metadata_create() {}
    void dovi_metadata_mux() {}
    void YCbCr2RGB() {}
    void paint() {
        drawn.push_back(arr_red[i][to_draw]);
        if (drawn.size() == 1 && after_first_draw) after_first_draw();
    }
    void rectangle() { paint(); }
    void circle() { paint(); }
    void triangle() { paint(); }
    void text() { paint(); }
    void image() { paint(); }
};

// REAL_RENDERER_METHODS

string command(int value, const string &type = "RECTANGLE") {
    return "DRAW=" + type + "\nBITS=8\nSOURCE_MAX=255\nDIM=10,10\nRGB="
        + ofToString(value) + ",0,0\nBG=0,0,0\nPOSITION=0,0\nEND=1\n";
}
void post(ofApp &app, const string &commands) {
    const string staging = app.path + ".new";
    { ofstream out(staging); out << commands; }
    if (rename(staging.c_str(), app.path.c_str())) throw runtime_error("rename failed");
    ofstream marker(app.tmp_dir + "/running/return");
    marker << "1\n";
}
void render(ofApp &app) {
    // openFrameworks automatically clears its buffer before every draw.
    app.drawn.clear();
    app.draw();
    now_us += 1000;
}
void expect(ofApp &app, const vector<int> &values, const char *message) {
    if (app.drawn != values) throw runtime_error(message);
}
int main(int argc, char **argv) {
    try {
        if (argc != 2) throw runtime_error("fixture directory required");
        ofApp app;
        app.tmp_dir = argv[1];
        app.path = app.tmp_dir + "/operations.txt";
        const string patch = command(128) + "FRAME=100\n";
        post(app, patch);
        app.update();
        if (access((app.tmp_dir + "/running/return").c_str(), F_OK) == 0)
            throw runtime_error("pattern notification was not consumed");
        render(app);
        expect(app, {128}, "first pattern is blank");
        for (int n = 0; n < 30; ++n) {
            post(app, patch);
            app.update();
            render(app);
            expect(app, {128}, "same-patch resend produced an empty frame");
        }
        app.update();
        post(app, command(192) + "FRAME=100\n");
        render(app);
        expect(app, {128}, "late notification interrupted the current frame");
        app.update();
        render(app);
        expect(app, {192}, "late notification was lost");

        post(app, command(20) + command(40) + command(60) + "FRAME=100\n");
        app.update();
        app.after_first_draw = [&] { post(app, command(200) + "FRAME=100\n"); };
        render(app);
        expect(app, {20, 40, 60}, "mid-frame notification produced a partial pattern");
        app.after_first_draw = nullptr;
        app.update();
        render(app);
        expect(app, {200}, "mid-frame notification was not applied on the next frame");

        post(app, command(10) + "FRAME=1\n" + command(30) + "FRAME=100\n");
        app.update();
        render(app);
        now_us += 2000;
        render(app);
        if (app.i != 1) throw runtime_error("animation fixture did not advance");
        post(app, command(90, "IMAGE") + "FRAME=100\n");
        app.update();
        render(app);
        expect(app, {90}, "animation-to-image switch retained the previous frame index");

        // Empty startup state must still notice later commands.
        app.entered = 0;
        app.n_draw[app.i] = 0;
        post(app, command(150) + "FRAME=100\n");
        app.update();
        render(app);
        expect(app, {150}, "empty renderer could not accept a pattern");
        post(app, command(60) + "FRAME=100\n");
        post(app, command(80) + "FRAME=100\n");
        post(app, command(100) + "FRAME=100\n");
        app.update();
        render(app);
        expect(app, {100}, "rapid posts did not select the latest complete pattern");
        return 0;
    } catch (const exception &error) {
        cerr << error.what() << endl;
        return 1;
    }
}
