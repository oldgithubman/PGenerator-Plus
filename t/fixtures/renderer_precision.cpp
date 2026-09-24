#include <algorithm>
#include <cmath>
#include <iostream>
#include <map>
#include <stdexcept>
#include <string>
#include <vector>
#include "rgb2ycbcr.h"

float ofClamp(float value, float low, float high) {
    return std::max(low, std::min(high, value));
}
std::vector<double> clear_color, style_color;
void ofSetColor(int r, int g, int b, int a=255) { style_color={double(r),double(g),double(b),double(a)}; }
void ofClear(float r, float g, float b, float a) { clear_color={r/255.,g/255.,b/255.,a/255.}; }
int ofGetWindowWidth() { return 1920; }
int ofGetWindowHeight() { return 1080; }
struct Texture { void bind() {} void unbind() {} };
struct Image { Texture texture; Texture &getTexture() { return texture; } };
struct Fbo { void begin() {} void end() {} };
struct Shader {
    std::map<std::string,std::vector<double>> values;
    bool active=false;
    void begin() { active=true; }
    void end() { active=false; }
    void setUniform1i(const char *n,int a) { values[n]={double(a)}; }
    void setUniform2f(const char *n,float a,float b) { values[n]={a,b}; }
    void setUniform3f(const char *n,float a,float b,float c) { values[n]={a,b,c}; }
    void setUniform3i(const char *n,int a,int b,int c) { values[n]={double(a),double(b),double(c)}; }
};
struct ofxRPI4Window {
    static int bit_depth,isHDR,isDoVi,is_std_DoVi,colorspace_on,shader_init,dv_profile;
    struct AVI { int output_format=1,rgb_quant_range=1,colorimetry=2,max_bpc=10; };
    static AVI avi_info;
    static Shader shader;
    // COLOUR_SHADER_PREDICATE
};
int ofxRPI4Window::bit_depth=10,ofxRPI4Window::isHDR=0,ofxRPI4Window::isDoVi=0;
int ofxRPI4Window::is_std_DoVi=0,ofxRPI4Window::colorspace_on=1,ofxRPI4Window::shader_init=0,ofxRPI4Window::dv_profile=2;
ofxRPI4Window::AVI ofxRPI4Window::avi_info;
Shader ofxRPI4Window::shader;
class ofApp {
public:
    int i=0,to_draw=0,solid_red=0,solid_green=0,solid_blue=0;
    int dv_source_red=0,dv_source_green=0,dv_source_blue=0,dv_source_max=255;
    int arr_source_range[1][1]={{0}},arr_source_max[1][1]={{1023}},arr_redbg[1][1]={{0}};
    float background_color[4]={0,0,0,1};
    std::vector<int> dv_background;
    Image img,float_img;
    Fbo fbo8,fbo10;
    void setColor(int,int,int);
    int normalizeSourceValue(int,int);
    void setBackground(int,int,int);
    void clearBackground(int,int,int,int);
    void restoreBackground();
    void setDoViBackground(int r,int g,int b) { dv_background={r,g,b}; }
    void shader_begin(int);
    void shader_end(int);
};
// REAL_PRECISION_METHODS

void require(bool ok,const char *message) { if(!ok) throw std::runtime_error(message); }
int packed(double value,int maximum) { return int(std::floor(value*maximum+0.5)); }
int main() {
    try {
        ofApp app;
        auto &window=ofxRPI4Window::avi_info;
        auto &shader=ofxRPI4Window::shader;
        for(int hdr : {0,1}) for(int bits : {8,10,12}) for(int format : {0,1,2}) for(int range : {0,1,2}) {
            ofxRPI4Window::isHDR=hdr;
            ofxRPI4Window::bit_depth=bits;
            window.output_format=format; window.rgb_quant_range=range;
            int maximum=(1<<bits)-1;
            for(int code=0;code<=maximum;++code) {
                app.arr_source_range[0][0]=0;
                app.setColor(code,maximum-code,code/2);
                app.shader_begin(0);
                require(shader.active==(format!=0 || bits!=8),"wrong shader selection");
                if(shader.active) {
                    require(shader.values["source_codes"]==std::vector<double>({double(code),double(maximum-code),double(code/2)}),"solid code was quantized");
                    require(shader.values["source_normalizer"][0]==maximum,"wrong source domain");
                }
                app.shader_end(0);
                app.setBackground(code,code,code);
                std::vector<int> expected=format==1 ? std::vector<int>{128<<(bits-8),128<<(bits-8),code}
                    : format==2 ? std::vector<int>{code,128<<(bits-8),128<<(bits-8)} : std::vector<int>{code,code,code};
                for(int channel=0;channel<3;++channel)
                    require(packed(clear_color[channel],maximum)==expected[channel],"background lost precision");
                auto previous=clear_color;
                ofClear(0,0,0,0); // OF automatic clear at the next frame
                app.restoreBackground();
                app.arr_redbg[0][0]=-1;
                app.setBackground(-1,-1,-1);
                require(clear_color==previous,"BG=-1 lost previous surround");
                app.arr_redbg[0][0]=0;
                app.arr_source_range[0][0]=1;
                int black=16<<(bits-8),span=219<<(bits-8);
                int expanded=std::max(0,std::min(maximum,int(std::floor((code-black)*double(maximum)/span+0.5))));
                int expected_code=(format==0 && range==1) ? expanded : code;
                require(app.normalizeSourceValue(code,1)==expected_code,"range conversion disagrees with wire domain");
                app.setColor(code,code,code);
                app.shader_begin(0);
                if(shader.active) require(shader.values["source_codes"][0]==expected_code,"range normalized twice");
                app.shader_end(0);
            }
            if(format!=0) {
                app.arr_source_range[0][0]=0;
                app.setBackground(maximum,0,0);
                double y=0.2126*maximum;
                double ratio=range==1 ? 224./219 : 256./255;
                int yy=int(std::floor(y+0.5));
                int cb=int(std::floor(-y/1.8556*ratio+(128<<(bits-8))+0.5));
                int cr=int(std::floor((maximum-y)/1.5748*ratio+(128<<(bits-8))+0.5));
                std::vector<int> expected=format==1 ? std::vector<int>{cb,cr,yy} : std::vector<int>{yy,cb,cr};
                for(int channel=0;channel<3;++channel)
                    require(packed(clear_color[channel],maximum)==std::max(0,std::min(maximum,expected[channel])),"coloured surround matrix or default range changed");
            }
        }
        window.output_format=1;
        ofxRPI4Window::bit_depth=10;
        app.shader_begin(1);
        require(shader.values["is_image"][0]==1,"texture path changed");
        app.shader_end(1);
        window.output_format=0;
        window.rgb_quant_range=1;
        for(int bits : {8,10}) for(int profile : {1,2}) for(int range : {0,1}) {
            ofxRPI4Window::bit_depth=bits;
            ofxRPI4Window::dv_profile=profile;
            app.arr_source_range[0][0]=range;
            // Revisit domains in both directions to catch stale source_max.
            for(int source_max : {255,1023,4095,1023,255,0}) {
                ofxRPI4Window::is_std_DoVi=1;
                ofxRPI4Window::isDoVi=1;
                app.arr_source_max[0][0]=source_max;
                int maximum=source_max ? source_max : 255;
                // Backgrounds retain the original DV domain even though the
                // tunnel surface is only 8/10 bits. BG=-1 must not repack it.
                app.dv_background.clear();
                app.setBackground(maximum,maximum/2,0);
                require(app.dv_background==std::vector<int>({maximum,maximum/2,0}),"DV background source domain changed");
                app.arr_redbg[0][0]=-1;
                app.setBackground(-1,-1,-1);
                require(app.dv_background==std::vector<int>({maximum,maximum/2,0}),"BG=-1 changed DV background");
                app.arr_redbg[0][0]=0;
                for(int code=-1;code<=maximum+1;++code) {
                    app.setColor(code,maximum-code,code/2);
                    // Every draw must upload both DV inputs; old values cannot
                    // make a missing upload appear to pass this check.
                    shader.values.clear();
                    app.shader_begin(0);
                    require(shader.active,"DV shader did not begin");
                    require(shader.values.at("source_rgb")==std::vector<double>({
                        double(std::max(0,std::min(maximum,code))),
                        double(std::max(0,std::min(maximum,maximum-code))),
                        double(std::max(0,std::min(maximum,code/2)))}),"DV codes changed");
                    require(shader.values.at("source_max")[0]==maximum,"DV source domain changed");
                    require(!shader.values.count("source_codes") && !shader.values.count("source_normalizer"),
                        "DV used link-depth inputs instead of original source codes");
                    app.shader_end(0);
                    require(!shader.active,"DV shader did not end");
                }
                // Switching back to SDR must replace the previous DV inputs.
                ofxRPI4Window::is_std_DoVi=0;
                ofxRPI4Window::isDoVi=0;
                window.output_format=1;
                app.setColor(81,84,85);
                shader.values.clear();
                app.shader_begin(0);
                require(shader.active,"SDR shader did not begin after DV");
                require(shader.values.at("source_codes")==std::vector<double>({81,84,85}),"SDR reused DV codes");
                require(shader.values.at("source_normalizer")[0]==(1<<bits)-1,"SDR reused DV source domain");
                require(!shader.values.count("source_rgb") && !shader.values.count("source_max"),"SDR uploaded DV inputs");
                app.shader_end(0);
                require(!shader.active,"SDR shader did not end after DV");
                window.output_format=0;
            }
        }
        std::cout << "Real renderer paths preserve every 8/10/12-bit code and DV source inputs\n";
        return 0;
    } catch(const std::exception &e) { std::cerr << e.what() << '\n'; return 1; }
}
