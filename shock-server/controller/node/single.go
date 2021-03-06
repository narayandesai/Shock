package node

import (
	"github.com/MG-RAST/Shock/shock-server/conf"
	e "github.com/MG-RAST/Shock/shock-server/errors"
	"github.com/MG-RAST/Shock/shock-server/logger"
	"github.com/MG-RAST/Shock/shock-server/node"
	"github.com/MG-RAST/Shock/shock-server/node/file"
	"github.com/MG-RAST/Shock/shock-server/node/filter"
	"github.com/MG-RAST/Shock/shock-server/preauth"
	"github.com/MG-RAST/Shock/shock-server/request"
	"github.com/MG-RAST/Shock/shock-server/responder"
	"github.com/MG-RAST/Shock/shock-server/user"
	"github.com/MG-RAST/Shock/shock-server/util"
	"github.com/stretchr/goweb/context"
	"io"
	"net/http"
	"strconv"
	"time"
)

// GET: /node/{id}
func (cr *NodeController) Read(id string, ctx context.Context) error {
	u, err := request.Authenticate(ctx.HttpRequest())
	if err != nil && err.Error() != e.NoAuth {
		return request.AuthError(err, ctx)
	}

	// Fake public user
	if u == nil {
		if conf.Bool(conf.Conf["anon-read"]) {
			u = &user.User{Uuid: ""}
		} else {
			return responder.RespondWithError(ctx, http.StatusUnauthorized, e.NoAuth)
		}
	}

	// Gather query params
	query := ctx.HttpRequest().URL.Query()

	var fFunc filter.FilterFunc = nil
	if _, ok := query["filter"]; ok {
		if filter.Has(query.Get("filter")) {
			fFunc = filter.Filter(query.Get("filter"))
		}
	}

	// Load node and handle user unauthorized
	n, err := node.Load(id, u.Uuid)
	if err != nil {
		if err.Error() == e.UnAuth {
			return responder.RespondWithError(ctx, http.StatusUnauthorized, e.UnAuth)
		} else if err.Error() == e.MongoDocNotFound {
			return responder.RespondWithError(ctx, http.StatusNotFound, "Node not found")
		} else {
			// In theory the db connection could be lost between
			// checking user and load but seems unlikely.
			logger.Error("Err@node_Read:LoadNode:" + id + ":" + err.Error())

			n, err = node.LoadFromDisk(id)
			if err != nil {
				err_msg := "Err@node_Read:LoadNodeFromDisk:" + id + ":" + err.Error()
				logger.Error(err_msg)
				return responder.RespondWithError(ctx, http.StatusInternalServerError, err_msg)
			}
		}
	}

	// Switch though param flags
	// ?download=1
	if _, ok := query["download"]; ok {
		if !n.HasFile() {
			return responder.RespondWithError(ctx, http.StatusBadRequest, "Node has no file")
		}
		filename := n.Id
		if _, ok := query["filename"]; ok {
			filename = query.Get("filename")
		}

		if _, ok := query["index"]; ok {
			//handling bam file
			if query.Get("index") == "bai" {
				s := &request.Streamer{R: []file.SectionReader{}, W: ctx.HttpResponseWriter(), ContentType: "application/octet-stream", Filename: filename, Size: n.File.Size, Filter: fFunc}

				var region string

				if _, ok := query["region"]; ok {
					//retrieve alingments overlapped with specified region
					region = query.Get("region")
				}

				argv, err := request.ParseSamtoolsArgs(ctx)
				if err != nil {
					return responder.RespondWithError(ctx, http.StatusBadRequest, "Invaid args in query url")
				}

				err = s.StreamSamtools(n.FilePath(), region, argv...)
				if err != nil {
					return responder.RespondWithError(ctx, http.StatusBadRequest, "error while involking samtools")
				}

				return nil
			}

			// if forgot ?part=N
			if _, ok := query["part"]; !ok {
				return responder.RespondWithError(ctx, http.StatusBadRequest, "Index parameter requires part parameter")
			}
			// open file
			r, err := n.FileReader()
			defer r.Close()
			if err != nil {
				err_msg := "Err@node_Read:Open: " + err.Error()
				logger.Error(err_msg)
				return responder.RespondWithError(ctx, http.StatusInternalServerError, err_msg)
			}
			// load index
			idx, err := n.Index(query.Get("index"))
			if err != nil {
				return responder.RespondWithError(ctx, http.StatusBadRequest, "Invalid index")
			}

			if idx.Type() == "virtual" {
				csize := conf.CHUNK_SIZE
				if _, ok := query["chunk_size"]; ok {
					csize, err = strconv.ParseInt(query.Get("chunk_size"), 10, 64)
					if err != nil {
						return responder.RespondWithError(ctx, http.StatusBadRequest, "Invalid chunk_size")
					}
				}
				idx.Set(map[string]interface{}{"ChunkSize": csize})
			}
			var size int64 = 0
			s := &request.Streamer{R: []file.SectionReader{}, W: ctx.HttpResponseWriter(), ContentType: "application/octet-stream", Filename: filename, Filter: fFunc}
			for _, p := range query["part"] {
				pos, length, err := idx.Part(p)
				if err != nil {
					return responder.RespondWithError(ctx, http.StatusBadRequest, "Invalid index part")
				}
				size += length
				s.R = append(s.R, io.NewSectionReader(r, pos, length))
			}
			s.Size = size
			err = s.Stream()
			if err != nil {
				// causes "multiple response.WriteHeader calls" error but better than no response
				err_msg := "err:@node_Read s.stream: " + err.Error()
				logger.Error(err_msg)
				responder.RespondWithError(ctx, http.StatusBadRequest, err_msg)
			}
		} else {
			nf, err := n.FileReader()
			defer nf.Close()
			if err != nil {
				// File not found or some sort of file read error.
				// Probably deserves more checking
				err_msg := "err:@node_Read node.FileReader: " + err.Error()
				logger.Error(err_msg)
				return responder.RespondWithError(ctx, http.StatusBadRequest, err_msg)
			}
			s := &request.Streamer{R: []file.SectionReader{nf}, W: ctx.HttpResponseWriter(), ContentType: "application/octet-stream", Filename: filename, Size: n.File.Size, Filter: fFunc}
			err = s.Stream()
			if err != nil {
				// causes "multiple response.WriteHeader calls" error but better than no response
				err_msg := "err:@node_Read: s.stream: " + err.Error()
				logger.Error(err_msg)
				responder.RespondWithError(ctx, http.StatusBadRequest, err_msg)
			}
		}
	} else if _, ok := query["download_url"]; ok {
		if !n.HasFile() {
			return responder.RespondWithError(ctx, http.StatusBadRequest, "Node has not file")
		} else if u.Uuid == "" {
			return responder.RespondWithError(ctx, http.StatusUnauthorized, e.NoAuth)
		} else {
			options := map[string]string{}
			if _, ok := query["filename"]; ok {
				options["filename"] = query.Get("filename")
			}
			if p, err := preauth.New(util.RandString(20), "download", n.Id, options); err != nil {
				err_msg := "err:@node_Read download_url: " + err.Error()
				logger.Error(err_msg)
				responder.RespondWithError(ctx, http.StatusInternalServerError, err_msg)
			} else {
				responder.RespondWithData(ctx, util.UrlResponse{Url: util.ApiUrl(ctx) + "/preauth/" + p.Id, ValidTill: p.ValidTill.Format(time.ANSIC)})
			}
		}
	} else {
		// Base case respond with node in json
		responder.RespondWithData(ctx, n)
	}
	return nil
}
